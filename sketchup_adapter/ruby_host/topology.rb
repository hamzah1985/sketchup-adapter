# Finite face intersections and connected edge topology. Calculations use
# copies in a common coordinate space; only the requested result context is
# edited. No vendor tool is special-cased here.
module Sketchup
  module Topology
    TOL = Geom::TOL
    IDENTITY = Geom::Transformation.new
    module_function

    def on_segment?(p, a, b)
      d = b-a
      return p.distance(a) <= TOL if d.length <= TOL
      t = (p-a).dot(d) / d.dot(d)
      t >= -TOL/d.length && t <= 1+TOL/d.length && p.distance(a+d*t) <= TOL
    end

    def unique(points)
      points.each_with_object([]) { |p, list| list << p unless list.any? { |q| q.distance(p) <= TOL } }
    end

    # Equivalent boundaries can have different starting vertices, winding or
    # collinear subdivisions. Those differences must not duplicate a surface
    # when geometry is exploded into an already populated drawing context.
    def same_loop?(first,second)
      simplify=lambda do |points|
        ring=points.dup
        loop do
          reduced=ring.each_with_index.reject { |p,i| ring[i-1].distance(ring[(i+1)%ring.length])>TOL && on_segment?(p,ring[i-1],ring[(i+1)%ring.length]) }.map(&:first)
          break if reduced.length==ring.length || reduced.length<3
          ring=reduced
        end
        ring
      end
      a=simplify.call(first);b=simplify.call(second)
      return false unless a.length==b.length
      index=b.index { |p| p.distance(a.first)<=TOL }
      return false unless index
      [1,-1].any? { |step| a.each_with_index.all? { |p,i| p.distance(b[(index+step*i)%b.length])<=TOL } }
    end
    def bounds(points)
      axes=points.map(&:to_a).transpose
      [axes.map(&:min),axes.map(&:max)]
    end
    def overlap?(a,b)
      (0..2).all? { |i| a[0][i]<=b[1][i]+TOL && b[0][i]<=a[1][i]+TOL }
    end

    def collect(items, transform, recurse, hidden, path = [])
      Array(items.respond_to?(:to_a) ? items.to_a : items).flat_map do |entity|
        next [] unless entity.valid?
        next [] if !hidden && entity.respond_to?(:hidden?) && entity.hidden?
        case entity
        when Face
          rings = entity.loops.map { |l| l.points.map { |p| p.transform(transform) } }
          [{type: :face, entity: entity, rings: rings, plane: Geom.fit_plane_to_points(rings.first), transform: transform.to_a, bounds: bounds(rings.first)}]
        when Edge
          points=entity.vertices.map { |v| v.position.transform(transform) }
          [{type: :edge, entity: entity, points: points, transform: transform.to_a, bounds: bounds(points)}]
        when Group, ComponentInstance
          definition = entity.definition
          next [] unless recurse && !path.include?(definition)
          collect(definition.entities, transform * entity.transformation, true, hidden, path+[definition])
        else []
        end
      end
    end

    def contains?(face, point)
      return false unless point.distance_to_plane(face[:plane]) <= TOL
      projection=face[:projection] ||= begin
        xa,ya,=Geom.newell(face[:rings].first).axes
        origin=face[:rings].first.first
        rings=face[:rings].map { |ring| ring.map { |p| d=p-origin; Geom::Point3d.new(d.dot(xa),d.dot(ya),0) } }
        [origin,xa,ya,rings]
      end
      origin,xa,ya,rings=projection
      d=point-origin
      p2=Geom::Point3d.new(d.dot(xa),d.dot(ya),0)
      return true if rings.any? { |ring| ring.each_with_index.any? do |a,i|
        b=ring[(i+1)%ring.length]
        dx=b.x-a.x;dy=b.y-a.y;length2=dx*dx+dy*dy
        t=length2<=TOL*TOL ? 0 : [[((p2.x-a.x)*dx+(p2.y-a.y)*dy)/length2,0].max,1].min
        (p2.x-a.x-t*dx)**2+(p2.y-a.y-t*dy)**2<=TOL*TOL
      end }
      Geom.point_in_polygon_2D(p2,rings.first) && !rings.drop(1).any? { |ring| Geom.point_in_polygon_2D(p2,ring) }
    end

    # Intervals of an infinite line that actually lie on a finite polygon.
    # Holes and concave loops can produce more than one interval.
    def intervals(face, line)
      origin, direction = line
      hits = []
      face[:rings].each do |ring|
        ring.each_with_index do |a,i|
          b = ring[(i+1)%ring.length]
          if (a-origin).cross(direction).length <= TOL && (b-origin).cross(direction).length <= TOL
            hits.concat([a,b])
          else
            p = Geom.intersect_line_line(line,[a,b])
            hits << p if p && on_segment?(p,a,b)
          end
        end
      end
      values = unique(hits).map { |p| (p-origin).dot(direction) }.sort
      values.each_cons(2).select { |a,b| b-a > TOL && contains?(face, origin+direction*((a+b)/2.0)) }
    end

    def face_face(a,b)
      line = Geom.intersect_plane_plane(a[:plane],b[:plane])
      if line
        intervals(a,line).product(intervals(b,line)).filter_map do |ia,ib|
          lo=[ia[0],ib[0]].max; hi=[ia[1],ib[1]].min
          [line[0]+line[1]*lo,line[0]+line[1]*hi] if hi-lo > TOL
        end
      elsif a[:rings].first.first.distance_to_plane(b[:plane]) <= TOL
        # Coplanar boundaries are finite cutters too.
        [[a,b],[b,a]].flat_map do |source,target|
          source[:rings].flat_map { |ring| ring.each_with_index.flat_map { |p,i| clip_segment(target,p,ring[(i+1)%ring.length]) } }
        end
      else []
      end
    end

    def clip_segment(face,a,b)
      return [] unless a.distance_to_plane(face[:plane]) <= TOL && b.distance_to_plane(face[:plane]) <= TOL
      segment_bounds=bounds([a,b])
      return [] unless overlap?(segment_bounds,face[:bounds])
      length=a.distance(b)
      return [] if length<=TOL
      direction=(b-a)*(1.0/length)
      hits=[a,b]
      face[:rings].each do |ring|
        ring.each_with_index do |p,i|
          q=ring[(i+1)%ring.length]
          next unless (0..2).all? { |axis| [p[axis],q[axis]].min<=segment_bounds[1][axis]+TOL && [p[axis],q[axis]].max>=segment_bounds[0][axis]-TOL }
          hits << p if on_segment?(p,a,b)
          hits << q if on_segment?(q,a,b)
          crossing=Geom.intersect_line_line([a,b],[p,q])
          hits << crossing if crossing && on_segment?(crossing,a,b) && on_segment?(crossing,p,q)
        end
      end
      values=unique(hits).map { |p| (p-a).dot(direction) }.sort
      values.each_cons(2).filter_map do |lo,hi|
        [a+direction*lo,a+direction*hi] if hi-lo>TOL && contains?(face,a+direction*((lo+hi)/2.0))
      end
    end

    def intersect(receiver,recurse,t1,target,t2,hidden,cutters)
      raise TypeError,'result container must be Sketchup::Entities' unless target.is_a?(Entities)
      existing_surfaces=target.faces.dup
      left=collect(receiver,Geom::Transformation.coerce(t1),recurse,hidden)
      right=collect(cutters,IDENTITY,true,true)
      segments=[]
      left.each do |a|
        right.each do |b|
          next unless overlap?(a[:bounds],b[:bounds])
          # Snapshot caches are private calculation data. Identity in a common
          # transform must not depend on whether one snapshot has been cached.
          next if a[:entity].equal?(b[:entity]) && a[:transform]==b[:transform]
          if a[:type]==:face && b[:type]==:face
            # Existing adjacent faces in the same drawing context already
            # have this boundary. Re-emitting nested cutter boundaries into
            # the parent would create spurious wires when recurse is true.
            next if !(a[:entity].edges & b[:entity].edges).empty? &&
              a[:transform].zip(b[:transform]).all? { |x,y| (x-y).abs<1e-12 }
            segments.concat(face_face(a,b))
          elsif a[:type]!=b[:type]
            face,edge = a[:type]==:face ? [a,b] : [b,a]
            next if edge[:entity].faces.include?(face[:entity]) &&
              edge[:points].all? { |p| face[:rings].flatten.any? { |q| p==q } }
            segments.concat(clip_segment(face,*edge[:points]))
          end
        end
      end
      inverse=Geom::Transformation.coerce(t2).inverse
      added=[]; seen={}
      segments.each do |a,b|
        a=a.transform(inverse); b=b.transform(inverse)
        next if a.distance(b)<=TOL
        key=[target.key(a),target.key(b)].sort
        next if seen[key]
        seen[key]=true
        added.concat(target.insert_segment(a,b))
      end
      # A closed cut completely inside a face never reaches its outer
      # boundary. It still creates an inner face and a surrounding hole,
      # which the caller can erase or extrude (window mullions, grilles).
      # Intersection edges in an empty helper context are wires. Only a cut
      # contained in an existing surface can create an inner face there.
      added.each do |e|
        next unless e.valid? && e.faces.empty?
        next unless existing_surfaces.any? { |f| f.valid? && e.vertices.all? { |v| [Face::PointInside,Face::PointOnEdge,Face::PointOnVertex].include?(f.classify_point(v.position)) } }
        e.find_faces
      end
      added.select(&:valid?).uniq
    end
  end

  class Entities
    def intersect_with(recurse,t1,target,t2,hidden,cutters)
      Topology.intersect(self,recurse,t1,target,t2,hidden,cutters)
    end

    alias_method :add_face_without_boundary_partition, :add_face
    def add_face(*args)
      points=points_from_args(args)
      normal=Geom.newell(points) if points.length>=3
      if normal && normal.valid?
        pairs=points.each_with_index.map { |p,i| [p,points[(i+1)%points.length]] }
        unless @plane_index
          @plane_index={}
          faces.each { |f| index_plane(f) if f.valid? }
        end
        n=normal.to_a;axis=(0..2).max_by { |i| n[i].abs }
        n=n.map { |v| -v } if n[axis]<0
        d=n.zip(points.first.to_a).sum { |a,b| a*b }
        ranges=n.map { |v| [((v-1e-8)*100_000).round,((v+1e-8)*100_000).round].uniq }
        dc=(d/Geom::TOL).round
        candidates=ranges[0].product(ranges[1],ranges[2],[dc-1,dc,dc+1]).flat_map { |key| @plane_index[key] || [] }
        # A candidate surface must contain the input polygon's bounding box.
        # Cache bounds alongside the existing plane index; geometric edits
        # invalidate that index and therefore invalidate this cache too.
        if !@face_partition_bounds_owner.equal?(@plane_index)
          @face_partition_bounds_owner=@plane_index
          @face_partition_bounds={}
        end
        input_bounds=Topology.bounds(points)
        target=candidates.find do |face|
          next false unless face.valid?
          face_bounds=(@face_partition_bounds[face] ||= Topology.bounds(face.outer_loop.points))
          next false unless (0..2).all? { |i| input_bounds[0][i]>=face_bounds[0][i]-Geom::TOL && input_bounds[1][i]<=face_bounds[1][i]+Geom::TOL }
          boundary=face.outer_loop.points
          next false unless points.all? { |p| boundary.each_with_index.any? { |a,i| Topology.on_segment?(p,a,boundary[(i+1)%boundary.length]) } }
          next false unless face.outer_loop.convex?
          chords=pairs.select { |a,b| face.classify_point(Geom.centroid([a,b]))==Face::PointInside }
          next false if chords.empty?
          if face.loops.length>1
            snapshot=Topology.collect([face],Topology::IDENTITY,false,true).first
            next false unless chords.all? { |a,b| (Topology.clip_segment(snapshot,a,b).sum { |p,q| p.distance(q) }-a.distance(b)).abs<=Geom::TOL }
          end
          true
        end
        if target
          previous=faces.dup
          pairs.each { |a,b| insert_segment(a,b) }
          # New fragments inherit the original surface's non-geometry state.
          (faces-previous).each { |fragment| copy_face_fragment_properties(target,fragment) }
          result=faces.find { |face| face.valid? && Topology.same_loop?(face.outer_loop.points,points) }
          return result if result
        end
      end
      add_face_without_boundary_partition(*args)
    end

    # Split both old and new wires at crossings, not just at input endpoints.
    # Shared Vertex objects are essential to edge.faces and later trimming.
    def insert_segment(a,b)
      a=Geom::Point3d.new(a.to_a); b=Geom::Point3d.new(b.to_a)
      return [] if a.distance(b)<=Geom::TOL
      nodes=[a,b]
      new_bounds=Topology.bounds([a,b])
      edges.dup.each do |old|
        next unless old.valid?
        p,q=old.start.raw,old.end.raw
        next unless (0..2).all? { |i| [p[i],q[i]].min<=new_bounds[1][i]+Geom::TOL && [p[i],q[i]].max>=new_bounds[0][i]-Geom::TOL }
        points=[a,b].select { |v| Topology.on_segment?(v,p,q) }
        nodes.concat([p,q].select { |v| Topology.on_segment?(v,a,b) })
        crossing=Geom.intersect_line_line([a,b],[p,q])
        if crossing && Topology.on_segment?(crossing,a,b) && Topology.on_segment?(crossing,p,q)
          points << crossing; nodes << crossing
        end
        # The original edge is invalid after its first split. Find the current
        # child covering the next point instead of retaining a stale edge.
        Topology.unique(points).each do |point|
          child=edges.find { |e| e.valid? && Topology.on_segment?(point,*e.vertices.map(&:position)) &&
            e.vertices.none? { |v| v.position.distance(point)<=Geom::TOL } }
          split_edge(child,point) if child
        end
      end
      direction=b-a
      Topology.unique(nodes).sort_by { |p| (p-a).dot(direction) }.each_cons(2).filter_map do |p,q|
        next if p.distance(q)<=Geom::TOL
        e=edge(vertex(p),vertex(q))
        split_faces_along_wire(e) unless faces.empty?
        e
      end
    end

    def add_line(a,b=nil)
      a,b=a if b.nil? && a.is_a?(Array) && a.length==2
      raise ArgumentError,'Expected two endpoints' if b.nil?
      a=a.position if a.is_a?(Vertex)
      b=b.position if b.is_a?(Vertex)
      insert_segment(a,b).first
    end

    # A wire can connect an outer boundary to a hole and back. Splitting only
    # simple loops leaves the old annulus overlapping its new regions. Walk
    # the planar graph, preserve untouched holes, and commit only a complete
    # area-preserving partition of the existing face.
    def split_holed_face_along_wire(face,new_edge)
      boundary=face.loops.flat_map(&:vertices)
      return false if (new_edge.vertices & boundary).empty?
      return false if face.edges.include?(new_edge)
      plane=face.plane
      return false unless new_edge.vertices.all? { |v| v.position.on_plane?(plane) }
      return false unless face.classify_point(Geom.centroid(new_edge.vertices.map(&:position)))==Face::PointInside
      normal=face.normal;xa,ya,=normal.axes;origin=face.outer_loop.points.first
      project=lambda { |p| d=p-origin;Geom::Point3d.new(d.dot(xa),d.dot(ya),0) }
      wires=edges.select do |e|
        !e.faces.include?(face) && e.vertices.all? { |v| v.position.on_plane?(plane) } &&
          face.classify_point(Geom.centroid(e.vertices.map(&:position)))==Face::PointInside
      end
      planar=(face.edges+wires).uniq
      links=Hash.new { |h,k| h[k]=[] }
      planar.each { |e| e.vertices.each { |v| links[v] << e.other_vertex(v) } }
      links.each { |v,others| others.sort_by! { |w| d=w.position-v.position;Math.atan2(d.dot(ya),d.dot(xa)) } }
      visited={};regions=[]
      planar.each do |edge|
        edge.vertices.each do |a|
          first=[a,edge.other_vertex(a)];pair=first;ring=[]
          loop do
            break if visited[pair]
            visited[pair]=true
            u,v=pair;ring << u
            around=links[v]
            pair=[v,around[(around.index(u)-1)%around.length]]
            break if pair==first
          end
          next unless pair==first && ring.length>=3 && ring.uniq.length==ring.length
          points=ring.map(&:position)
          next unless Geom.newell(points).dot(normal)>0 && Face.poly_area(points)>Geom::TOL**2
          polygon=points.map(&project)
          interior=points.each_with_index.any? do |p,i|
            q=points[(i+1)%points.length];direction=q-p
            next false unless direction.valid?
            middle=Geom::Point3d.linear_combination(0.5,p,0.5,q)
            probe=middle+normal.cross(direction).normalize*(Geom::TOL*4)
            Geom.point_in_polygon_2D(project.call(probe),polygon) && face.classify_point(probe)==Face::PointInside
          end
          next unless interior
          holes=face.loops.drop(1).select do |hole|
            (hole.vertices & ring).empty? && Geom.point_in_polygon_2D(project.call(hole.points.first),polygon)
          end.map(&:vertices)
          regions << [ring,holes]
        end
      end
      return false unless regions.length>=2
      area=regions.sum { |ring,holes| Face.poly_area(ring.map(&:position))-holes.sum { |hole| Face.poly_area(hole.map(&:position)) } }
      return false if (area-face.area).abs>[face.area.abs*1e-8,Geom::TOL**2*10].max
      face.edges.each { |e| e.internal_faces.delete(face) }
      regions.each_with_index do |(ring,holes),index|
        fragment=index==0 ? face : Face.new(self,ring)
        fragment.instance_variable_set(:@loops,[Loop.new(fragment,ring,true)])
        copy_face_fragment_properties(face,fragment)
        @items << fragment unless index==0
        ring.each_with_index do |v,i|
          edge(v,ring[(i+1)%ring.length]).internal_faces << fragment
        end
        holes.each { |hole| fragment.add_hole(hole) }
      end
      @plane_index=nil
      true
    end

    def connected_to(seed)
      found={}; queue=[seed]
      until queue.empty?
        current=queue.pop
        next if found[current] || !current.valid?
        found[current]=true
        neighbours=case current
        when Face then current.edges
        when Edge then current.faces+current.vertices.flat_map(&:edges)
        else []
        end
        queue.concat(neighbours.reject { |e| found[e] })
      end
      found.keys
    end
  end

  class Edge
    def all_connected; parent_entities.connected_to(self); end
    def find_faces
      return 0 unless valid?
      component=all_connected.grep(Edge)
      axis=self.end.position-start.position
      normals=[]
      component.each do |e|
        normal=axis.cross(e.end.position-e.start.position)
        next unless normal.valid?
        normal.normalize!
        normals << normal unless normals.any? { |n| n.parallel?(normal) }
      end
      before=parent_entities.faces.length
      normals.each do |normal|
        xa,ya,=normal.axes
        origin=start.position
        planar=component.select { |e| e.vertices.all? { |v| (v.position-origin).dot(normal).abs<=Geom::TOL } }
        links=Hash.new { |h,k| h[k]=[] }
        planar.each { |e| e.vertices.each { |v| links[v] << e.other_vertex(v) } }
        links.each do |v,neighbours|
          neighbours.sort_by! { |w| d=w.position-v.position; Math.atan2(d.dot(ya),d.dot(xa)) }
        end
        visited={}
        planar.each do |e|
          e.vertices.each do |a|
            b=e.other_vertex(a); first=[a,b]; pair=first; ring=[]
            loop do
              break if visited[pair]
              visited[pair]=true
              u,v=pair; ring << u
              neighbours=links[v]
              pair=[v,neighbours[(neighbours.index(u)-1)%neighbours.length]]
              break if pair==first
            end
            next unless pair==first && ring.uniq.length==ring.length && ring.length>=3
            next unless ring.each_with_index.any? { |v,i| [v,ring[(i+1)%ring.length]].sort_by(&:object_id)==vertices.sort_by(&:object_id) }
            pts=ring.map(&:position)
            next unless Geom.newell(pts).dot(normal)>0 && Face.poly_area(pts)>Geom::TOL**2
            parent_entities.add_face(pts)
          end
        end
      end
      parent_entities.faces.length-before
    end
  end
end
