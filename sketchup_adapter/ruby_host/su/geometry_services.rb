# Scene geometry queries and real solid predicates. Boolean arithmetic is
# delegated to IngeTrazo's material-preserving manifold kernel.
module Sketchup
  def self.observers;@observers ||= [];end
  module Container
    def manifold?
      return false if entities.any? { |e| (e.is_a?(Group) || e.is_a?(ComponentInstance)) && e.valid? }
      faces=entities.grep(Face).select(&:valid?)
      !faces.empty? && entities.grep(Edge).all? { |e| !e.valid? || e.faces.count(&:valid?)==2 }
    end

    def volume
      return 0.0 unless manifold?
      sum=entities.grep(Face).sum do |face|
        face.loops.each_with_index.sum do |loop,index|
          points=loop.points
          next 0.0 if points.length<3
          direction=Geom.newell(points).dot(face.normal)<0 ? -1.0 : 1.0
          direction *= -1 if index>0
          a=Geom::Vector3d.new(points[0].to_a)
          direction*(1...points.length-1).sum { |i| a.dot(Geom::Vector3d.new(points[i].to_a).cross(Geom::Vector3d.new(points[i+1].to_a)))/6.0 }
        end
      end
      x,y,z=transformation.xaxis,transformation.yaxis,transformation.zaxis
      (sum*x.dot(y.cross(z))).abs
    end

    def bridge_boolean(operation,other)
      raise ArgumentError,'Expected two valid solid groups/components' unless valid? && other.respond_to?(:manifold?) && other.valid?
      return nil unless manifold? && other.manifold?
      response=Bridge.call('solid_operation','action'=>operation,'first'=>Host.export_container(self),'second'=>Host.export_container(other))
      raise 'The native solid service did not respond' unless response.is_a?(Hash)
      raise response['error'] unless response['ok']
      return nil if response['groups'].to_a.empty?
      parent=@parent_entities
      result=Array(response['groups']).map { |data| Host.build_pick_entity(data,parent,0) }
      erase! unless operation=='trim'
      other.erase!
      operation=='split' ? result : result.first
    end
    def intersect(other);bridge_boolean('intersect',other);end
    def union(other);bridge_boolean('union',other);end
    def outer_shell(other);bridge_boolean('outer_shell',other);end
    def subtract(other);bridge_boolean('subtract',other);end
    def trim(other);bridge_boolean('trim',other);end
    def split(other);bridge_boolean('split',other);end
    def equals?(other);other.respond_to?(:definition) && definition.equal?(other.definition) && transformation.to_a==other.transformation.to_a;end
  end

  class Model
    def raytest(ray,wysiwyg=true)
      origin,direction=Geom.line_parts(ray)
      raise ArgumentError,'A ray needs a nonzero direction' if direction.length<1e-12
      direction=direction.normalize
      best=nil
      walk=lambda do |entities,transform,path|
        entities.each do |entity|
          next unless entity.valid?
          next if wysiwyg && ((entity.respond_to?(:hidden?) && entity.hidden?) || (entity.respond_to?(:layer) && !entity.layer.visible?))
          if entity.is_a?(Face)
            points=entity.outer_loop.points.map { |p| p.transform(transform) }
            normal=Geom.newell(points)
            next if normal.length<1e-10
            point=Geom.intersect_line_plane([origin,direction],[points[0],normal])
            next unless point
            distance=(point-origin).dot(direction)
            next if distance<1e-8 || best && distance>=best[0]
            local=point.transform(transform.inverse)
            next unless [1,2,4].include?(entity.classify_point(local))
            best=[distance,point,path+[entity]]
          elsif entity.is_a?(Group) || entity.is_a?(ComponentInstance)
            walk.call(entity.entities,transform*entity.transformation,path+[entity])
          end
        end
      end
      walk.call(@entities,Geom::Transformation.new,[])
      response=Bridge.call('scene_raytest','origin'=>origin.to_a.map { |v| v*Host::INCH },'direction'=>direction.to_a,'wysiwyg'=>wysiwyg)
      if response.is_a?(Hash) && response['ok'] && response['hit']
        data=response['hit'];point=Geom::Point3d.new(data['point'].map { |v| v/Host::INCH })
        distance=(point-origin).dot(direction)
        if !best || distance<best[0]
          container=Host.build_pick_entity(data['geometry'],Entities.new(self),0)
          face=container.entities.grep(Face).first
          best=[distance,point,[container,face].compact]
        end
      end
      best && [best[1],best[2]]
    end
    def raycast(origin,direction);raytest([origin,direction]);end
  end
end
