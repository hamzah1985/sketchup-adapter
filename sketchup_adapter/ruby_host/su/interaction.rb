# Shared, model-free interaction services. Native cursor proxies always live
# in private Entities collections; none can become document geometry.
module Geom
  def self.closest_points(first, second)
    p, u = line_parts(first); q, v = line_parts(second)
    a, b, c = u.dot(u), u.dot(v), v.dot(v)
    raise ArgumentError, 'A line needs a nonzero direction' if a < 1e-24 || c < 1e-24
    w = p-q; d, e = u.dot(w), v.dot(w); den = a*c-b*b
    if den.abs <= a*c*1e-14
      s, t = 0.0, e/c
    else
      s, t = (b*e-c*d)/den, (a*e-b*d)/den
    end
    [p+u*s, q+v*t]
  end
end

module Sketchup
  class View
    attr_reader :inference_reference, :inference_line, :tooltip

    def reset_interaction
      @inference_reference = @inference_line = nil
      @input_hint = nil
      @native_hit_cache = {}
    end

    def lock_inference(first = nil, second = nil)
      if first.nil?
        @inference_line = nil
        return false
      end
      raise ArgumentError, 'Expected valid InputPoints' unless first.is_a?(InputPoint) && first.valid? && (!second || second.is_a?(InputPoint) && second.valid?)
      a = @inference_reference || (second ? second.position : first.position)
      b = first.position
      direction = second ? first.position-second.position : b-a
      if direction.length < 1e-10
        axis = @cursor['snap_axis']
        direction = {'x'=>X_AXIS,'y'=>Y_AXIS,'z'=>Z_AXIS}[axis]
      end
      return false unless direction && direction.length > 1e-10
      @inference_reference = a.clone
      @inference_line = [a.clone,direction.normalize]
      true
    end

    def inference_locked?; !!@inference_line; end

    def interaction_state
      {'reference'=>@inference_reference&.to_a,
       'direction'=>@inference_line && @inference_line[1].to_a,
       'point'=>@input_hint && @input_hint['point'],
       'snap'=>@input_hint && @input_hint['snap']}
    end

    def resolve_input(reference = nil)
      data = @cursor.dup
      @inference_reference = reference && reference.valid? ? reference.position : nil unless @inference_line
      return data unless data['valid'] && data['point']
      point = Geom::Point3d.new(data['point'])
      if @inference_line
        anchor, direction = @inference_line
        if InputPoint::POINT_KINDS.include?(data['snap'])
          point = point.project_to_line(@inference_line)
        elsif data['ray']
          ray = [Geom::Point3d.new(data['ray'][0]),Geom::Vector3d.new(data['ray'][1])]
          point = Geom.closest_points(ray,@inference_line)[1]
        else
          point = point.project_to_line(@inference_line)
        end
        data['point'] = point.to_a
        data['snap'] = 'reference' unless InputPoint::POINT_KINDS.include?(data['snap']) && point.distance(Geom::Point3d.new(@cursor['point'])) < 1e-7
        data['dof'] = data['snap'] == 'reference' ? 1 : 0
      elsif @inference_reference && !InputPoint::POINT_KINDS.include?(data['snap']) && data['linear_mode'] != 'off'
        anchor = @inference_reference
        delta = point-anchor; length = delta.length
        if length > 1e-8
          candidates = [X_AXIS,Y_AXIS,Z_AXIS].each_with_index.map do |axis,index|
            projected = point.project_to_line([anchor,axis])
            alignment = delta.dot(axis).abs/length
            [alignment,projected,index]
          end
          alignment, projected, index = candidates.max_by(&:first)
          if alignment >= Math.cos(3.0*Math::PI/180.0)
            data['point'] = projected.to_a; data['snap']='axis';data['snap_axis']=%w[x y z][index];data['dof']=1
          end
        end
      end
      @input_hint = data
      data
    end

    def inputpoint(x = nil, y = nil, reference = nil)
      InputPoint.new(resolve_input(reference),@pick_face).attach_native(self)
    end

    def tooltip=(text)
      @tooltip = text.to_s
      Bridge.notify('tooltip','text'=>@tooltip)
    end

    def pick_helper(*_args)
      PickHelper.new(@pick_target,@pick_face,@cursor['xform'],self)
    end

    def native_hits
      records = @cursor['hits']
      return nil unless records.is_a?(Array)
      @native_hit_cache ||= {}
      current = {}
      hits = records.filter_map do |record|
        key = record['token'] || JSON.generate(record)
        stamp = JSON.generate(record.reject { |k,_| %w[distance depth].include?(k) })
        cached = @native_hit_cache[key]
        if cached && cached[:stamp] == stamp && (record['kind']!='face' || cached[:entity].equal?(@pick_face))
          hit = cached.dup
        else
          xf = record['xform'] ? Geom::Transformation.new(record['xform']) : Geom::Transformation.new
          if record['kind'] == 'face' && @pick_face
            entity = @pick_face
            path = [@pick_target,@pick_face].compact
            xf = Geom::Transformation.new
          elsif record['kind'] == 'edge'
            native=Host.native_edge(record['native_token']) if record['native_token'] && Host.respond_to?(:native_edge)
            if native
              entity=native;path=[native];xf=Geom::Transformation.new
            else
            definition = ComponentDefinition.new('Native pick edges')
            collection = definition.entities
            a,b = record['points'].map { |p| Geom::Point3d.new(p) }
            entity = collection.edge(collection.vertex(a),collection.vertex(b))
            owner = nil
            if record['owner']
              owner = Group.new(definition,xf)
              owner.name = record['owner']['name'].to_s
              (record['owner']['attrs'] || {}).each { |dn,attrs| attrs.each { |k,v| owner.set_attribute(dn,k,v) } }
            end
            path = [owner,entity].compact
            end
          else
            next
          end
          hit = {entity:entity,path:path,transform:xf,stamp:stamp}
        end
        hit[:distance] = record['distance'].to_f
        hit[:depth] = record['depth'].to_f
        current[key] = hit
        hit
      end
      @native_hit_cache = current
      hits
    end
  end

  class InputPoint
    POINT_KINDS = %w[endpoint midpoint arc_midpoint intersection origin center centre component_origin close].freeze
    EDGE_KINDS = %w[on_edge axis reference extension through_point from_point perp_face].freeze

    def attach_native(view)
      hits = view.native_hits || []
      candidates = hits.select { |h| h[:entity].is_a?(Edge) }
      best = candidates.min_by do |h|
        a,b = h[:entity].vertices.map { |v| v.position.transform(h[:transform]) }
        if @cursor['snap']=='endpoint'
          [position.distance(a),position.distance(b)].min
        else
          ab=b-a; t=ab.dot(ab)>1e-18 ? [[(position-a).dot(ab)/ab.dot(ab),0].max,1].min : 0
          position.distance(a+ab*t)
        end
      end
      @native_edge = nil;@native_vertex=nil;@native_transform=Geom::Transformation.new
      endpoint = best && POINT_KINDS.include?(@cursor['snap']) && best[:entity].vertices.any? { |v| position.distance(v.position.transform(best[:transform])) < 1e-5 }
      if best && (@cursor['snap']=='on_edge' || @cursor['snap']=='endpoint' || @cursor['snap']=='midpoint' || endpoint)
        @native_edge=best[:entity];@native_transform=best[:transform]
        @native_vertex=@native_edge.vertices.min_by { |v| position.distance(v.position.transform(@native_transform)) } if @cursor['snap']=='endpoint' || endpoint
      end
      self
    end

    def pick(view,x=0,y=0,reference=nil)
      copy!(view.inputpoint(x,y,reference))
      valid?
    end

    def copy!(other)
      raise ArgumentError,'Expected an InputPoint' unless other.is_a?(InputPoint)
      @cursor=other.instance_variable_get(:@cursor).dup
      @cursor['point']=@cursor['point'].dup if @cursor['point']
      @face=other.face
      @native_edge=other.instance_variable_get(:@native_edge)
      @native_vertex=other.instance_variable_get(:@native_vertex)
      @native_transform=other.transformation
      self
    end

    def degrees_of_freedom
      return 3 unless valid?
      return @cursor['dof'] if @cursor.key?('dof')
      return 0 if POINT_KINDS.include?(@cursor['snap'])
      return 1 if EDGE_KINDS.include?(@cursor['snap'])
      @cursor['snap']=='on_face' ? 2 : 3
    end

    def edge
      return @native_edge if @native_edge
      return nil unless @face && %w[endpoint midpoint on_edge].include?(@cursor['snap'])
      @face.edges.min_by { |e| position.distance(position.project_to_line(e.line)) }
    end

    def vertex
      return @native_vertex if @native_vertex
      return nil unless @face && @cursor['snap']=='endpoint'
      @face.vertices.min_by { |v| v.position.distance(position) }
    end

    def transformation; @native_transform || Geom::Transformation.coerce(@cursor['xform'] || Geom::Transformation.new); end
    def tooltip
      @cursor['snap_label'] || {'on_edge'=>'On Edge','on_face'=>'On Face','reference'=>'Inference locked','axis'=>'On Axis'}.fetch(@cursor['snap'],@cursor['snap'].to_s.tr('_',' ').split.map(&:capitalize).join(' '))
    end
    def draw(view)
      return false unless valid?
      color=@cursor['snap_color'] || [45,145,70,255]
      color=color.map { |v| (v*255).round } if color.length==3 && color.all? { |v| v<=1 }
      view.draw_points([position],7,1,Color.new(color));true
    end
    def clear
      @cursor={};@face=@native_edge=@native_vertex=@native_transform=nil;self
    end
  end

  class PickHelper
    attr_reader :view
    def initialize(target=nil,face=nil,xform=nil,view=nil)
      @target,@face,@xform,@view=target,face,Geom::Transformation.coerce(xform || Geom::Transformation.new),view
      @hits=nil
    end
    def do_pick(_x=nil,_y=nil,aperture=0,*_args)
      hits=@view && @view.native_hits
      @hits=hits && hits.select { |h| h[:entity].is_a?(Face) || h[:distance] <= (aperture.to_f>0 ? aperture.to_f : 8.0) }
      count
    end
    def hits
      @hits ||= (@view && @view.native_hits) || [@face || @target].compact.map { |e| {entity:e,path:[@target,@face].compact.uniq,transform:@xform,depth:0} }
    end
    def count; hits.length; end
    def element_at(i); h=hits[i];h && h[:path].first; end
    def leaf_at(i); h=hits[i];h && h[:entity]; end
    def path_at(i); h=hits[i];h && h[:path].dup; end
    def transformation_at(i); h=hits[i];h && h[:transform]; end
    def depth_at(i); h=hits[i];h && h[:path].length; end
    def best_picked; hits.first && hits.first[:path].first; end
    def all_picked; hits.map { |h| h[:path].first }; end
    def picked_face; hits.map { |h| h[:entity] }.find { |e| e.is_a?(Face) }; end
    def picked_edge; hits.map { |h| h[:entity] }.find { |e| e.is_a?(Edge) }; end
    def picked_element
      hits.map { |hit| hit[:entity] }.find { |entity| entity.is_a?(Drawingelement) && !entity.is_a?(Edge) && !entity.is_a?(Face) }
    end
  end
end
