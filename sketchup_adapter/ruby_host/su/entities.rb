# SketchUp model/entities emulation: enough of the real API, with SketchUp's
# modelling semantics (vertex welding, coplanar face carving, push/pull,
# follow-me), for Window Crafter's unmodified builder to run.

module Sketchup
  @next_id = 0
  def self.next_id; @next_id += 1; end

  class AttributeDictionary
    include Enumerable
    attr_reader :name
    def initialize(name); @name = name; @h = {}; end
    def [](k); @h[k.to_s]; end
    def []=(k, v); @h[k.to_s] = v; end
    def keys; @h.keys; end
    def key?(key); @h.key?(key.to_s); end
    alias has_key? key?
    def values; @h.values; end
    def each(&b); @h.each(&b); end
    alias each_pair each
    def length; @h.length; end
    alias size length
    alias count length
    def delete_key(k); @h.delete(k.to_s); end
    def to_h; @h.dup; end
    def valid?; true; end
    def attribute_dictionaries; nil; end
  end

  class AttributeDictionaries
    include Enumerable
    def initialize; @d = {}; end
    def [](n); @d[n.to_s]; end
    def fetch(n); @d[n.to_s] ||= AttributeDictionary.new(n.to_s); end
    def each(&b); @d.values.each(&b); end
    def delete(n); @d.delete(n.is_a?(AttributeDictionary) ? n.name : n.to_s); end
    def length; @d.length; end
    alias size length
    alias count length
    def to_h; @d.each_with_object({}) { |(k, v), h| h[k] = v.to_h }; end
  end

  class Entity
    attr_accessor :parent_entities
    def initialize
      @entity_id = Sketchup.next_id
      @deleted = false
      @attrs = nil
    end
    def entityID; @entity_id; end
    def persistent_id; @entity_id; end
    def valid?; !@deleted; end
    def deleted?; @deleted; end
    def mark_deleted!; @deleted = true; end
    def model; Sketchup.active_model; end
    def parent; @parent_entities ? @parent_entities.parent : nil; end
    def typename; self.class.name.split("::").last; end
    def attribute_dictionaries; @attrs ||= AttributeDictionaries.new; end
    def attribute_dictionary(name, create = false)
      return @attrs[name] if @attrs && @attrs[name]
      return nil unless create
      (@attrs ||= AttributeDictionaries.new).fetch(name)
    end
    def set_attribute(dict, key, value)
      attribute_dictionary(dict.to_s, true)[key] = value
      value
    end
    def get_attribute(dict, key, default = nil)
      d = attribute_dictionary(dict.to_s)
      return default unless d
      v = d[key]
      v.nil? ? default : v
    end
    def delete_attribute(dict, key = nil)
      return false unless @attrs && @attrs[dict.to_s]
      key.nil? ? @attrs.delete(dict.to_s) : @attrs[dict.to_s].delete_key(key)
      true
    end
    def add_observer(_o); true; end
    def remove_observer(_o); true; end
    def to_s; "#<#{self.class.name}:#{@entity_id}>"; end
    alias inspect to_s
  end

  class Drawingelement < Entity
    attr_reader :material, :back_material
    attr_accessor :casts_shadows, :receives_shadows
    attr_writer :hidden, :visible
    def initialize; super; @hidden = false; @layer = nil; end
    # SketchUp accepts material names and colors as well as Material objects,
    # but reads always return a Material. Preserve existing named materials so
    # their texture, opacity and identity remain available to extensions.
    def material=(value); @material = resolve_material(value); end
    def back_material=(value); @back_material = resolve_material(value); end
    def resolve_material(value)
      return nil if value.nil?
      return value if value.is_a?(Material)
      materials = Sketchup.active_model.materials
      if value.is_a?(String)
        existing = materials[value]
        return existing if existing
        unless Color::NAMES.key?(value.strip.downcase) || value.strip.match?(/\A#?[0-9a-f]{6}\z/i)
          raise ArgumentError, "Unknown material or color: #{value}"
        end
      end
      unless value.is_a?(String) || value.is_a?(Color) || value.is_a?(Array) || value.is_a?(Integer)
        raise TypeError, 'Expected a Material, material name, or color'
      end
      color = Color.new(value)
      name = "[Color #{color.to_a.join(',')}]"
      # A user may already have a textured material with this display name.
      # Do not change that material when creating a plain color swatch.
      material = materials.add(name)
      material.color = color
      material.alpha = color.alpha.to_f / 255.0
      material
    end
    def hidden?; @hidden; end
    def hidden; @hidden; end
    def visible?; !@hidden; end
    def visible=(v); @hidden = !v; end
    def layer; @layer || Sketchup.active_model.layers[0]; end
    def layer=(l); @layer = l.is_a?(String) ? Sketchup.active_model.layers.add(l) : l; end
    def erase!
      @parent_entities.erase_entities(self) if @parent_entities && valid?
      mark_deleted!
      true
    end
    def casts_shadows?; @casts_shadows != false; end
    def receives_shadows?; @receives_shadows != false; end
  end

  class Vertex < Entity
    def edges; @edges.dup; end
    # Kernel-only mutation access. Public API arrays are snapshots: filtering
    # a plugin's local array must never delete the model's adjacency links.
    def internal_edges; @edges; end
    def initialize(pos, ents); super(); @pos = pos; @edges = []; @parent_entities = ents; end
    def position; @pos.clone; end
    def raw; @pos; end
    def move_to!(p); @parent_entities.rekey(self, @pos, p); @pos = Geom::Point3d.new(p.to_a); end
    def faces; @edges.flat_map(&:faces).uniq; end
    def loops; faces.flat_map(&:loops).select { |l| l.vertices.include?(self) }; end
    def used_by?(e); e.respond_to?(:vertices) && e.vertices.include?(self); end
    def curve_interior?; false; end
    def common_edge(v); @edges.find { |e| e.other_vertex(self) == v }; end
  end

  class Curve < Entity
    def edges; @edges.dup; end
    def initialize(edges); super(); @edges = edges.dup; end
    def vertices
      return [] if @edges.empty?
      vs = [@edges.first.start]
      @edges.each { |e| vs << (e.start == vs.last ? e.end : e.start) }
      vs
    end
    def first_edge; @edges.first; end
    def last_edge; @edges.last; end
    def count_edges; @edges.length; end
    def each_edge(&b); @edges.each(&b); end
    def length; @edges.sum(&:length); end
    def is_polygon?; false; end
  end

  class ArcCurve < Curve
    attr_reader :center, :radius, :normal, :start_angle, :end_angle, :xaxis, :yaxis
    def initialize(edges, center, radius, normal, xaxis, a0, a1)
      super(edges)
      @center = center; @radius = radius; @normal = normal; @xaxis = xaxis
      @yaxis = normal.cross(xaxis); @start_angle = a0; @end_angle = a1
    end
    def circular?; true; end
    def plane; [@center, @normal]; end
  end

  class Edge < Drawingelement
    attr_reader :start, :end
    def faces; @faces.dup; end
    def internal_faces; @faces; end
    attr_accessor :curve
    def initialize(a, b, ents)
      super(); @start = a; @end = b; @faces = []; @soft = false; @smooth = false; @parent_entities = ents
    end
    def vertices; [@start, @end]; end
    def soft?; @soft; end
    def soft; @soft; end
    def soft=(v); @soft = v ? true : false; end
    def smooth?; @smooth; end
    def smooth; @smooth; end
    def smooth=(v); @smooth = v ? true : false; end
    def length(t = nil)
      a = @start.position; b = @end.position
      if t
        a = a.transform(t); b = b.transform(t)
      end
      a.distance(b)
    end
    def line; [@start.position, (@end.position - @start.position).normalize]; end
    def other_vertex(v); v == @start ? @end : @start; end
    def used_by?(e); e.is_a?(Face) ? @faces.include?(e) : vertices.include?(e); end
    def reversed_in?(face)
      l = face.loops.find { |lp| lp.edges.include?(self) }
      return false unless l
      vs = l.vertices
      i = vs.index(@start)
      vs[(i + 1) % vs.length] != @end
    end
    def explode_curve; @curve = nil; self; end
    def split(p)
      @parent_entities.split_edge(self, Geom::Point3d.new(p.to_a))
    end
    def common_face(e); (@faces & e.faces).first; end
    def bounds; Geom::BoundingBox.new.add(@start.position, @end.position); end
    def erase!
      @parent_entities.erase_entities(self) if @parent_entities && valid?
      true
    end
  end

  class Loop < Entity
    attr_reader :face
    def initialize(face, verts, outer)
      super(); @face = face; @verts = verts; @outer = outer
    end
    def vertices; @verts.dup; end
    def set_vertices(v); @verts = v; end
    def outer?; @outer; end
    def edges
      ents = @face.parent_entities
      @verts.each_with_index.map { |v, i| ents.edge_between(v, @verts[(i + 1) % @verts.length]) }.compact
    end
    def edgeuses; edges; end
    def points; @verts.map(&:position); end
    def convex?
      pts = points
      n = @face.normal
      pts.each_with_index.all? do |p, i|
        a = pts[i - 1]; b = pts[(i + 1) % pts.length]
        (p - a).cross(b - p).dot(n) >= -1e-9
      end
    end
  end

  class UVHelper
    def initialize(face, front, back, tw, th); @face = face; @tw = tw; @th = th; end
    def get_front_UVQ(p); @face.uv_for(p, true); end
    def get_back_UVQ(p); @face.uv_for(p, false); end
  end

  class Face < Drawingelement
    # Face material changes must be distinguished from inherited native attrs.
    # Imports reset these flags after reconstructing a read-only proxy.
    def material=(value)
      result = super
      @adapter_paint_dirty_front = true if @adapter_surface_token
      result
    end
    def back_material=(value)
      result = super
      @adapter_paint_dirty_back = true if @adapter_surface_token
      result
    end
    # Native face proxies cannot yet persist SketchUp attribute dictionaries.
    # Reject writes before a plugin commits an apparently successful operation
    # whose data would be lost. Bridge bookkeeping remains internal and works.
    def guard_native_face_attribute_write!(name)
      return unless @adapter_surface_token && name.to_s != '_ingetrazo_bridge'
      raise RuntimeError, 'IngeTrazo adapter cannot save plugin attributes on native faces yet; the operation may be incomplete.'
    end
    def set_attribute(dict, key, value)
      guard_native_face_attribute_write!(dict)
      super
    end
    def delete_attribute(dict, key = nil)
      guard_native_face_attribute_write!(dict)
      super
    end
    def attribute_dictionary(name, create = false)
      guard_native_face_attribute_write!(name) if create
      super
    end

    # SketchUp Face#classify_point result codes. Plugins compare these as
    # Sketchup::Face constants (Tile Crafter uses the inside/edge/vertex set
    # when it finds adjoining wall faces).
    PointUnknown = 0
    PointInside = 1
    PointOnVertex = 2
    PointOnEdge = 4
    PointOutside = 8
    PointNotOnPlane = 16

    def loops; @loops.dup; end
    attr_accessor :parent_face, :uv_mapping, :uv_mapping_back
    def initialize(ents, outer_verts)
      super()
      @parent_entities = ents
      @loops = [Loop.new(self, outer_verts, true)]
      @parent_face = nil
      @uv_mapping = nil
      Sketchup.active_model.note_generated_face if Sketchup.active_model.respond_to?(:note_generated_face)
    end
    def outer_loop; @loops.first; end
    def vertices; @loops.flat_map(&:vertices); end
    def edges; @loops.flat_map(&:edges).uniq; end
    def normal; Geom.newell(outer_loop.points); end
    def plane
      n = normal
      p = outer_loop.vertices.first.position
      [n.x, n.y, n.z, -n.dot(Geom::Vector3d.new(p.to_a))]
    end
    def area(t = nil)
      polys = @loops.map { |l| t ? l.points.map { |p| p.transform(t) } : l.points }
      outer = self.class.poly_area(polys[0])
      outer - polys[1..-1].sum { |h| self.class.poly_area(h) }
    end
    def self.poly_area(pts)
      n = Geom.newell(pts)
      s = Geom::Vector3d.new(0, 0, 0)
      pts.each_with_index { |a, i| s += Geom::Vector3d.new(a.to_a).cross(Geom::Vector3d.new(pts[(i + 1) % pts.length].to_a)) }
      (s.dot(n) / 2.0).abs
    end
    def bounds; Geom::BoundingBox.new.add(outer_loop.points); end
    def reverse!
      @loops.each { |l| l.set_vertices(l.vertices.reverse) }
      m = material; self.material = back_material; self.back_material = m if false
      self
    end
    def add_hole(verts)
      # Hole boundaries run opposite the outer loop. Push/pull reuses this
      # direction for the reveal walls; accepting a same-way loop inverts them.
      verts = verts.reverse if Geom.newell(verts.map(&:position)).dot(normal) > 0
      @loops << Loop.new(self, verts, false)
      verts.each_with_index do |v, i|
        e = @parent_entities.edge(v, verts[(i + 1) % verts.length])
        e.internal_faces << self unless e.faces.include?(self)
      end
    end
    def remove_hole_matching(verts)
      ids = verts.map(&:object_id).sort
      gone = @loops.select { |l| !l.outer? && l.vertices.map(&:object_id).sort == ids }
      gone.each { |l| l.edges.each { |e| e.internal_faces.delete(self) } }
      @loops -= gone
    end
    def classify_point(p)
      return PointUnknown if @loops.empty? || outer_loop.vertices.empty?
      point = Geom::Point3d.new(p.to_a)
      return PointNotOnPlane if point.distance_to_plane(plane) > Geom::TOL
      pts2, pp = project2d([point])
      pt = pp.first
      outer2 = pts2[0]
      return PointOnVertex if @loops.any? { |loop| loop.vertices.any? { |v| v.position.distance(point) <= Geom::TOL } }
      return PointOnEdge if pts2.any? { |ring| on_poly_border?(pt, ring) }
      return PointOutside unless Geom.point_in_polygon_2D(pt, outer2)
      return PointOutside if pts2[1..-1].any? { |hole| Geom.point_in_polygon_2D(pt, hole) }
      PointInside
    end
    def on_poly_border?(pt, poly); poly.each_with_index.any? { |a, i| seg_dist2d(pt, a, poly[(i + 1) % poly.length]) <= Geom::TOL }; end
    def seg_dist2d(p, a, b)
      dx = b.x - a.x; dy = b.y - a.y
      l2 = dx * dx + dy * dy
      t = l2 < 1e-18 ? 0 : [[((p.x - a.x) * dx + (p.y - a.y) * dy) / l2, 0].max, 1].min
      Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    end

    # 2D projection in this face's plane: [[outer2d, hole2d...], extra2d]
    def project2d(extra = [])
      xa, ya, _ = normal.axes
      o = outer_loop.vertices.first.position
      f = lambda { |p| v = p - o; Geom::Point3d.new(v.dot(xa), v.dot(ya), 0) }
      [@loops.map { |l| l.points.map(&f) }, extra.map { |p| f.call(Geom::Point3d.new(p.to_a)) }]
    end

    def all_connected; @parent_entities.connected_to(self); end

    # --- Texture mapping ---------------------------------------------------
    def position_material(mat, pts, front = true)
      if front
        self.material = mat
        @uv_mapping = pts.map { |p| Geom::Point3d.new(p.to_a) }
      else
        self.back_material = mat
        @uv_mapping_back = pts.map { |p| Geom::Point3d.new(p.to_a) }
      end
      self
    end
    def texture_positioned?; !@uv_mapping.nil?; end
    def clear_texture_position(front = true)
      if front
        @uv_mapping = nil; @adapter_paint_dirty_front = true if @adapter_surface_token
      else
        @uv_mapping_back = nil; @adapter_paint_dirty_back = true if @adapter_surface_token
      end
    end
    def get_UVHelper(front = true, back = true, _tw = nil); UVHelper.new(self, front, back, nil, nil); end
    def get_texture_projection(_f); nil; end
    def set_texture_projection(*_a); nil; end

    # UV (in texture tiles) for a point, following SketchUp's rules.
    def uv_for(p, front = true)
      mat = front ? material : back_material
      tex = mat && mat.respond_to?(:texture) ? mat.texture : nil
      tw = tex ? tex.width : 1.0; th = tex ? tex.height : 1.0
      mapping = front ? @uv_mapping : @uv_mapping_back
      p = Geom::Point3d.new(p.to_a)
      if mapping && mapping.length >= 6
        pairs = mapping.each_slice(2).to_a
        p0, uv0 = pairs.first
        p1, uv1 = pairs[1]
        p2, uv2 = pairs.drop(2).max_by { |point, _uv| (p1 - p0).cross(point - p0).length }
        e1 = p1 - p0; e2 = p2 - p0; dp = p - p0
        a = e1.dot(e1); b = e1.dot(e2); c = e2.dot(e2)
        det = a * c - b * b
        if det.abs > 1e-18
          s = (dp.dot(e1) * c - dp.dot(e2) * b) / det
          t = (dp.dot(e2) * a - dp.dot(e1) * b) / det
          return Geom::Point3d.new(uv0.x + s * (uv1.x - uv0.x) + t * (uv2.x - uv0.x),
                                   uv0.y + s * (uv1.y - uv0.y) + t * (uv2.y - uv0.y), 1)
        end
      end
      if mapping && mapping.length >= 4
        p0, uv0, p1, uv1 = mapping[0], mapping[1], mapping[2], mapping[3]
        ax = p1 - p0
        du = uv1.x - uv0.x; dv = uv1.y - uv0.y
        len_uv = Math.hypot(du, dv)
        return Geom::Point3d.new(0, 0, 1) if ax.length < 1e-12 || len_uv < 1e-12
        n = normal
        # map: texture u axis direction in model space
        ang = Math.atan2(dv, du)
        scale = ax.length / len_uv # model length per texture unit along mapping
        axn = ax.normalize
        bxn = n.cross(axn).normalize
        # rotate so that ax corresponds to (du,dv) direction
        c = Math.cos(-ang); s = Math.sin(-ang)
        uax = Geom::Vector3d.new(axn.x * c - bxn.x * s, axn.y * c - bxn.y * s, axn.z * c - bxn.z * s)
        vax = n.cross(uax).normalize
        d = p - p0
        u = uv0.x + d.dot(uax) / scale
        v = uv0.y + d.dot(vax) / scale
        return Geom::Point3d.new(u, v, 1)
      end
      xa, ya = Sketchup::Face.projection_basis(normal)
      Geom::Point3d.new(Geom::Vector3d.new(p.to_a).dot(xa) / tw, Geom::Vector3d.new(p.to_a).dot(ya) / th, 1)
    end

    # SketchUp's default in-plane texture axes for a face normal.
    def self.projection_basis(n)
      n = n.normalize
      if n.z.abs > 0.999
        xa = Geom::Vector3d.new(1, 0, 0)
        ya = Geom::Vector3d.new(0, n.z > 0 ? 1 : -1, 0)
      else
        xa = Geom::Vector3d.new(0, 0, 1).cross(n).normalize
        ya = n.cross(xa).normalize
      end
      [xa, ya]
    end

    # --- Triangulation (PolygonMesh) -----------------------------------------
    def triangles
      rings2, = project2d
      rings3 = @loops.map(&:points)
      Sketchup::Triangulate.triangulate(rings2, rings3)
    end

    def mesh(flags = 0, t = nil)
      pm = Geom::PolygonMesh.new
      n = normal
      triangles.each do |tri|
        pts = tri.map { |p| t ? p.transform(t) : p }
        idx = pts.map { |p| pm.add_point(p) }
        pm.polys << idx
        tri.each_with_index do |p, k|
          pm.uvs_front[idx[k] - 1] = uv_for(p, true)
          pm.uvs_back[idx[k] - 1] = uv_for(p, false)
          pm.normals_list[idx[k] - 1] = t ? n.transform(t).normalize : n
        end
      end
      pm
    end

    # Compare simple cyclic boundaries in linear time, normalizing only
    # consecutive collinear points. Degenerate rings are rejected explicitly.
    def simplify_boundary_cycle(points)
      raise ArgumentError, 'Invalid Push/Pull boundary' if points.length < 3
      count=points.length
      simplified=[]
      points.each_index do |i|
        previous=points[(i-1)%count]; point=points[i]; following=points[(i+1)%count]
        left=point-previous; right=following-point
        raise ArgumentError, 'Repeated adjacent Push/Pull vertex' if left.length<=Geom::TOL || right.length<=Geom::TOL
        collinear=left.cross(right).length<=Geom::TOL*(left.length+right.length) && left.dot(right)>0
        simplified << point unless collinear
      end
      if simplified.length<3
        raise ArgumentError, 'Degenerate Push/Pull boundary' unless Geom.newell(points).valid?
        return points
      end
      simplified
    end
    def same_vertex_cycle?(a, b)
      return false unless a.length == b.length
      starts=b.each_index.select { |i| a[0] == b[i] }
      return false if starts.empty?
      raise ArgumentError, 'Ambiguous repeated vertex in Push/Pull boundary' if starts.length>1
      start=starts.first; n=a.length
      a.each_index.all? { |i| a[i] == b[(start+i)%n] } ||
        a.each_index.all? { |i| a[i] == b[(start-i)%n] }
    end
    def same_boundary_cycle?(first, second)
      return true if same_vertex_cycle?(first,second)
      same_vertex_cycle?(simplify_boundary_cycle(first),simplify_boundary_cycle(second))
    end
    def pushpull_segments_touch?(a,b,c,d)
      return true if seg_dist2d(a,c,d)<=Geom::TOL || seg_dist2d(b,c,d)<=Geom::TOL ||
                     seg_dist2d(c,a,b)<=Geom::TOL || seg_dist2d(d,a,b)<=Geom::TOL
      cross=lambda { |p,q,r| (q.x-p.x)*(r.y-p.y)-(q.y-p.y)*(r.x-p.x) }
      ac=cross.call(a,b,c);ad=cross.call(a,b,d);ca=cross.call(c,d,a);cb=cross.call(c,d,b)
      ac*ad<0 && ca*cb<0
    end
    def safe_pushpull_target?(target, cap)
      return false unless target.contains_polygon_strict?(cap)
      rings,projected=target.project2d(cap)
      # Prevent an edge from leaving a concave exterior or crossing/touching
      # an existing hole, and do not swallow a whole hole inside the cap.
      rings.each do |ring|
        ring.each_index do |i|
          projected.each_index do |j|
            return false if pushpull_segments_touch?(ring[i],ring[(i+1)%ring.length],projected[j],projected[(j+1)%projected.length])
          end
        end
      end
      rings.drop(1).none? { |hole| Geom.point_in_polygon_2D(hole.first,projected,true) || Geom.point_in_polygon_2D(projected.first,hole,true) }
    end
    def conflicting_pushpull_cap?(face, cap)
      rings, projected=face.project2d(cap)
      rings.each do |ring|
        ring.each_index do |i|
          projected.each_index do |j|
            return true if pushpull_segments_touch?(ring[i],ring[(i+1)%ring.length],projected[j],projected[(j+1)%projected.length])
          end
        end
      end
      cap_inside=Geom.point_in_polygon_2D(projected.first,rings.first,true) &&
        rings.drop(1).none? { |hole| Geom.point_in_polygon_2D(projected.first,hole,true) }
      cap_inside || Geom.point_in_polygon_2D(rings.first.first,projected,true)
    end
    def validate_pushpull_loop!(loop)
      vertices=loop.vertices
      raise ArgumentError, 'Repeated Push/Pull vertex' if vertices.map(&:object_id).uniq.length!=vertices.length
    end
    private :simplify_boundary_cycle, :same_vertex_cycle?, :same_boundary_cycle?, :pushpull_segments_touch?, :safe_pushpull_target?, :conflicting_pushpull_cap?, :validate_pushpull_loop!

    # --- Push/Pull -----------------------------------------------------------
    def pushpull(dist, copy = false, _m = false)
      dist = dist.to_f
      return nil if dist.abs < 1e-9
      ents = @parent_entities
      n = normal
      off = n * dist
      carved = !@parent_face.nil? && @parent_face.valid?
      neighbours = edges.flat_map(&:faces).uniq.reject { |f| f.equal?(self) || !f.valid? }
      solid_neighbours = neighbours.reject { |f| f.normal.parallel?(n) }
      @loops.each { |loop| validate_pushpull_loop!(loop) }
      rings = @loops.map(&:points)

      if !carved && !solid_neighbours.empty? && !copy &&
         solid_neighbours.all? { |f| f.normal.perpendicular?(n) }
        # A face on a box: SketchUp just moves it (perpendicular sides stretch).
        vertices.uniq.each { |v| v.move_to!(v.position + off) }
        return nil
      end

      void = carved && dist < 0
      out_sign = void ? -1.0 : 1.0
      mat = material; bmat = back_material

      # Resolve and validate the target before creating any side faces.
      cap_outer = rings[0].map { |p| p + off }
      cap_holes = rings[1..-1].map { |r| r.map { |p| p + off } }
      through = nil
      if carved || !solid_neighbours.empty?
        matches=[];matching_hole_owners=[];comparison_budget=0
        ents.faces.each do |f|
          next if f.equal?(self) || !f.valid? || !f.normal.parallel?(n)
          next unless cap_outer.first.on_plane?(f.plane)
          f.loops.each { |loop| validate_pushpull_loop!(loop) }
          outer=f.outer_loop.points
          holes=f.loops.drop(1).map(&:points)
          if same_boundary_cycle?(outer,cap_outer)
            matches << f
            next
          end
          if holes.any? { |hole| same_boundary_cycle?(hole,cap_outer) }
            matching_hole_owners << f
            next
          end
          comparison_budget+=cap_outer.length*(outer.length+holes.sum(&:length))
          raise ArgumentError, 'Push/Pull target is too complex to inspect safely' if comparison_budget>1_000_000 || cap_outer.length*(outer.length+holes.sum(&:length))>250_000
          if f.contains_polygon?(cap_outer)
            matches << f
          elsif conflicting_pushpull_cap?(f,cap_outer)
            raise ArgumentError, 'Ambiguous overlapping Push/Pull target; operation stopped'
          end
        end
        raise ArgumentError, 'Multiple Push/Pull targets overlap; operation stopped' if matches.length>1
        through=matches.first
        if matching_hole_owners.any? { |face| !through || !through.parent_face.equal?(face) }
          raise ArgumentError, 'Push/Pull encounters an already open boundary; operation stopped'
        end
      end
      already_split=false
      if through && same_boundary_cycle?(through.outer_loop.points, cap_outer)
        unless same_vertex_cycle?(through.outer_loop.points, cap_outer)
          raise ArgumentError, 'Coincident Push/Pull boundary requires edge splitting; operation stopped'
        end
        parent=through.parent_face
        matching_holes=parent && parent.valid? ? parent.loops.drop(1).select { |loop| same_boundary_cycle?(loop.points, cap_outer) } : []
        unless parent && parent.valid? && through.loops.length == 1 && matching_holes.length == 1 &&
               same_vertex_cycle?(matching_holes.first.points, cap_outer)
          raise ArgumentError, 'Ambiguous coincident Push/Pull target; operation stopped'
        end
        already_split=true
      elsif through && !safe_pushpull_target?(through,cap_outer)
        # Boundary touching, crossing, and swallowed holes require a topology
        # operation this compatibility layer cannot safely infer here.
        raise ArgumentError, 'Ambiguous Push/Pull boundary intersection; operation stopped'
      end

      # Index parent hole edges once. Vertex identities are shared within
      # an Entities collection, making winding checks constant-time per side.
      parent_edge_directions={}
      outer_vertices=@loops[0].vertices
      if carved
        @parent_face.loops.drop(1).each do |loop|
          vs=loop.vertices
          vs.each_index do |i|
            first=vs[i].object_id;second=vs[(i+1)%vs.length].object_id
            key=first<second ? [first,second] : [second,first]
            raise ArgumentError, 'Ambiguous parent boundary edge' if parent_edge_directions.key?(key)
            parent_edge_directions[key]=first<second ? 1 : -1
          end
        end
      end

      # Sides.
      rings.each_with_index do |ring, ring_index|
        ring.each_with_index do |a, i|
          b = ring[(i + 1) % ring.length]
          quad = [a, b, b + off, a + off]
          # (b-a) x off points outward from the prism for d>0.
          want = (b - a).cross(off).normalize * (dist > 0 ? 1.0 : -1.0) * out_sign
          quad.reverse! if Geom.newell(quad).dot(want) < 0
          if carved && ring_index==0
            first=outer_vertices[i].object_id
            second=outer_vertices[(i+1)%ring.length].object_id
            key=first<second ? [first,second] : [second,first]
            parent_direction=parent_edge_directions[key]
            if parent_direction
              direction=first<second ? 1 : -1
              side_forward=quad.each_index.any? { |j| quad[j]==a && quad[(j+1)%quad.length]==b }
              side_direction=side_forward ? direction : -direction
              quad.reverse! if side_direction==parent_direction
            end
          end
          f = ents.add_face_raw(quad)
          f.material = mat if f && mat
        end
      end

      # Cap (possibly punching through the far side of a solid).
      if through
        if already_split
          ents.erase_face_only(through)
        else
          hv = cap_outer.map { |p| ents.vertex(p) }
          through.add_hole(hv)
        end
        cap_holes.each { |h| ents.add_face_raw(h) }
      else
        cap = ents.add_face_raw(cap_outer)
        if cap
          want = n * (dist > 0 ? 1.0 : -1.0) * out_sign
          cap.reverse! if cap.normal.dot(want) < 0
          cap_holes.each { |h| cap.add_hole(h.map { |p| ents.vertex(p) }) }
          cap.material = mat if mat
          cap.back_material = bmat if bmat
        end
      end

      if copy
        nil
      elsif carved || !solid_neighbours.empty?
        ents.erase_face_only(self)
      else
        # A lone face stays as the back of the new solid, facing away.
        reverse! if normal.dot(off) > 0
      end
      nil
    end

    def contains_polygon?(pts)
      _, pp = project2d(pts)
      rings2, = project2d
      pp.all? { |q| Geom.point_in_polygon_2D(q, rings2[0], true) } &&
        rings2[1..-1].none? { |h| pp.any? { |q| Geom.point_in_polygon_2D(q, h, false) } }
    end

    # --- Follow Me -----------------------------------------------------------
    def followme(path)
      path = [path] unless path.is_a?(Array)
      path = path.flat_map { |e| e.is_a?(Curve) ? e.edges : e }.select { |e| e.is_a?(Edge) }
      return false if path.empty?
      pts = Sketchup::Sweep.ordered_points(path)
      return false if pts.length < 2
      closed = pts.first == pts.last
      pts.pop if closed
      ents = @parent_entities
      original_profile_edges=edges
      path_inside_profile=classify_point(pts.first)==Face::PointInside
      prof = @loops.map(&:points)
      mat = material
      # Start the profile at the path vertex nearest to it.
      c = Geom.centroid(prof[0])
      start = (0...pts.length).min_by { |i| pts[i].distance(c) }
      pts = pts.rotate(start) if closed
      rings_at = Sketchup::Sweep.sweep(prof, pts, closed)
      first_direction=(pts[1]-pts[0]).normalize
      reverse_sides=Geom.newell(rings_at[0][0]).dot(first_direction)<0
      count = rings_at.length
      segs = closed ? count : count - 1
      prof.each_with_index do |_r, ri|
        m = prof[ri].length
        segs.times do |s|
          a = rings_at[s][ri]; b = rings_at[(s + 1) % count][ri]
          m.times do |k|
            q = [a[k], a[(k + 1) % m], b[(k + 1) % m], b[k]]
            q.reverse! if reverse_sides
            next if Geom.newell(q).length < 1e-9
            f = ents.add_face_raw(q)
            f.material = mat if f && mat
          end
        end
      end
      if closed
        ents.erase_face_only(self)
      else
        # The start cap must face away from the path, and the end cap along
        # it. Keeping both in the profile's original winding made signed
        # volume depend on the model's world origin.
        self.edges.each { |edge| edge.internal_faces.delete(self) }
        start_vertices=rings_at[0][0].map { |p| ents.vertex(p) }
        @loops=[Loop.new(self,start_vertices,true)]
        start_vertices.each_with_index { |v,i| ents.edge(v,start_vertices[(i+1)%start_vertices.length]).internal_faces << self }
        rings_at[0][1..-1].each { |ring| add_hole(ring.map { |p| ents.vertex(p) }) }
        reverse! if normal.dot(first_direction)>0
        endf = ents.add_face_raw(rings_at[-1][0])
        if endf
          rings_at[-1][1..-1].each { |h| endf.add_hole(h.map { |p| ents.vertex(p) }) }
          endf.material = mat if mat
          endf.reverse! if endf.normal.dot(pts[-1]-pts[-2])<0
        end
      end
      original_profile_edges.each { |edge| edge.erase! if edge.valid? && edge.faces.empty? && !path.include?(edge) }
      path.each do |edge|
        next unless edge.valid? && edge.parent_entities.equal?(ents) && ents.respond_to?(:insert_segment)
        if path_inside_profile && edge.faces.empty?
          edge.erase!
          next
        end
        next if edge.faces.length>=2
        ents.insert_segment(*edge.vertices.map(&:position))
      end
      true
    end
  end

  module Sweep
    def self.ordered_points(edges)
      edges = edges.dup
      first = edges.shift
      chain = [first.start.position, first.end.position]
      until edges.empty?
        nxt = edges.find { |e| e.start.position == chain.last || e.end.position == chain.last }
        if nxt
          chain << (nxt.start.position == chain.last ? nxt.end.position : nxt.start.position)
        else
          nxt = edges.find { |e| e.start.position == chain.first || e.end.position == chain.first }
          break unless nxt
          chain.unshift(nxt.start.position == chain.first ? nxt.end.position : nxt.start.position)
        end
        edges.delete(nxt)
      end
      chain
    end

    # Carry each profile ring along the path, projecting onto the mitre plane
    # at every path vertex.
    def self.sweep(rings, pts, closed)
      n = pts.length
      dirs = (0...(closed ? n : n - 1)).map { |i| (pts[(i + 1) % n] - pts[i]).normalize }
      planes = (0...n).map do |i|
        din = closed ? dirs[(i - 1) % dirs.length] : (i > 0 ? dirs[i - 1] : nil)
        dout = closed ? dirs[i % dirs.length] : (i < dirs.length ? dirs[i] : nil)
        nn = if din && dout then (din + dout) else (din || dout) end
        nn = dout || din if nn.length < 1e-9
        [pts[i], nn.normalize]
      end
      # Project the profile (drawn anywhere near pts[0]) onto plane 0 along dir0.
      cur = rings.map { |r| r.map { |p| Geom.intersect_line_plane([p, dirs[0]], planes[0]) || p } }
      out = [cur]
      (1...n).each do |i|
        d = dirs[(i - 1) % dirs.length]
        cur = cur.map { |r| r.map { |p| Geom.intersect_line_plane([p, d], planes[i]) || p + d } }
        out << cur
      end
      out
    end
  end

  module Triangulate
    # Ear clipping with hole bridging. rings2: 2D rings (outer, holes...),
    # rings3: the matching 3D points. Returns [[p3,p3,p3], ...].
    def self.triangulate(rings2, rings3)
      pts = []
      idx_outer = ring_indices(pts, rings2[0], rings3[0], true)
      holes = rings2[1..-1].each_with_index.map { |r, i| ring_indices(pts, r, rings3[i + 1], false) }
      poly = idx_outer
      holes.sort_by { |h| -h.map { |k| pts[k][0].x }.max }.each { |h| poly = bridge(pts, poly, h) }
      ear_clip(pts, poly).map { |t| t.map { |k| pts[k][1] } }
    end

    def self.signed_area(pts, idx)
      s = 0.0
      idx.each_with_index { |a, i| b = idx[(i + 1) % idx.length]; s += pts[a][0].x * pts[b][0].y - pts[b][0].x * pts[a][0].y }
      s / 2
    end

    def self.ring_indices(pts, r2, r3, ccw)
      base = pts.length
      r2.each_with_index { |p, i| pts << [p, r3[i]] }
      idx = (base...pts.length).to_a
      a = signed_area(pts, idx)
      idx.reverse! if (a > 0) != ccw
      idx
    end

    def self.seg_intersect?(p1, p2, p3, p4)
      d = lambda { |a, b, c| (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
      d1 = d.call(p3, p4, p1); d2 = d.call(p3, p4, p2); d3 = d.call(p1, p2, p3); d4 = d.call(p1, p2, p4)
      ((d1 > 1e-12 && d2 < -1e-12) || (d1 < -1e-12 && d2 > 1e-12)) &&
        ((d3 > 1e-12 && d4 < -1e-12) || (d3 < -1e-12 && d4 > 1e-12))
    end

    def self.bridge(pts, poly, hole)
      hi = hole.max_by { |k| pts[k][0].x }
      hp = pts[hi][0]
      all_edges = lambda do
        es = []
        poly.each_with_index { |a, i| es << [a, poly[(i + 1) % poly.length]] }
        hole.each_with_index { |a, i| es << [a, hole[(i + 1) % hole.length]] }
        es
      end.call
      cands = poly.each_with_index.sort_by { |k, _| pts[k][0].distance(hp) }
      pick = cands.find do |k, _|
        q = pts[k][0]
        all_edges.none? { |a, b| next false if [a, b].include?(k) || [a, b].include?(hi); seg_intersect?(q, hp, pts[a][0], pts[b][0]) }
      end || cands.first
      pi = pick[1]
      h0 = hole.index(hi)
      hole_seq = hole.rotate(h0) + [hi]
      poly[0..pi] + hole_seq + poly[pi..-1]
    end

    def self.ear_clip(pts, poly)
      tris = []
      v = poly.dup
      guard = 0
      while v.length > 3 && guard < 100_000
        guard += 1
        found = false
        v.length.times do |i|
          a = v[i - 1]; b = v[i]; c = v[(i + 1) % v.length]
          pa = pts[a][0]; pb = pts[b][0]; pc = pts[c][0]
          cross = (pb.x - pa.x) * (pc.y - pa.y) - (pb.y - pa.y) * (pc.x - pa.x)
          next if cross <= 1e-14
          inside = v.any? do |k|
            next false if [a, b, c].include?(k)
            pk = pts[k][0]
            next false if pk == pa || pk == pb || pk == pc
            in_tri?(pk, pa, pb, pc)
          end
          next if inside
          tris << [a, b, c]
          v.delete_at(i)
          found = true
          break
        end
        unless found
          # Degenerate remainder: fan it.
          (1...v.length - 1).each { |i| tris << [v[0], v[i], v[i + 1]] }
          return tris
        end
      end
      tris << v if v.length == 3
      tris
    end

    def self.in_tri?(p, a, b, c)
      d1 = (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)
      d2 = (p.x - c.x) * (b.y - c.y) - (b.x - c.x) * (p.y - c.y)
      d3 = (p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y)
      neg = d1 < -1e-14 || d2 < -1e-14 || d3 < -1e-14
      pos = d1 > 1e-14 || d2 > 1e-14 || d3 > 1e-14
      !(neg && pos)
    end
  end

  class ConstructionPoint < Drawingelement
    attr_reader :position
    def initialize(p); super(); @position = Geom::Point3d.new(p.to_a); end
  end

  class ConstructionLine < Drawingelement
    attr_accessor :position, :direction, :start, :end
    def initialize(a, b)
      super();@position=Geom::Point3d.new(a.to_a)
      @direction=b.is_a?(Geom::Point3d) ? b-@position : Geom::Vector3d.new(b.to_a)
    end
  end

  class Text < Drawingelement
    attr_accessor :text, :point, :vector
  end

  class Entities
    include Enumerable
    attr_reader :parent
    def initialize(parent)
      @parent = parent
      @items = []
      @vmap = {}
      @emap = {}
    end
    def model; Sketchup.active_model; end
    def each(&b); @items.dup.each(&b); end
    def to_a; @items.dup; end
    def length; @items.length; end
    alias size length
    alias count length
    def [](i); @items[i]; end
    def empty?; @items.empty?; end
    def faces; @items.grep(Face); end
    def edges; @items.grep(Edge); end
    def active_section_plane; nil; end
    def add_observer(_o); true; end
    def remove_observer(_o); true; end
    def build; yield self; end

    def key(p); [(p.x / Geom::TOL).round, (p.y / Geom::TOL).round, (p.z / Geom::TOL).round]; end
    def find_vertex(p)
      k = key(p)
      return @vmap[k] if @vmap[k]
      # neighbour cells guard against rounding at cell borders
      [-1, 0, 1].each { |dx| [-1, 0, 1].each { |dy| [-1, 0, 1].each { |dz|
        v = @vmap[[k[0] + dx, k[1] + dy, k[2] + dz]]
        return v if v && v.raw.distance(p) <= Geom::TOL
      } } }
      nil
    end
    def vertex(p)
      p = Geom::Point3d.new(p.to_a)
      find_vertex(p) || (@vmap[key(p)] = Vertex.new(p, self))
    end
    def rekey(v, old, newp)
      @plane_index = nil
      @vmap.delete(key(old)) if @vmap[key(old)].equal?(v)
      @vmap[key(Geom::Point3d.new(newp.to_a))] = v
    end
    def edge_between(a, b)
      @emap[[a.object_id, b.object_id].sort]
    end
    def edge(a, b)
      k = [a.object_id, b.object_id].sort
      e = @emap[k]
      return e if e && e.valid?
      e = Edge.new(a, b, self)
      @emap[k] = e
      a.internal_edges << e; b.internal_edges << e
      @items << e
      e
    end

    def add_line(a, b)
      a = Geom::Point3d.new(a.to_a); b = Geom::Point3d.new(b.to_a)
      return nil if a == b
      [a,b].each do |p|
        edges.dup.each do |e|
          next unless e.valid? && p.on_line?(e.line)
          t = (p - e.start.position).dot(e.end.position - e.start.position)
          next unless t > Geom::TOL * e.length && t < e.length * e.length - Geom::TOL * e.length
          split_edge(e, p)
        end
      end unless faces.empty?
      e = edge(vertex(a), vertex(b))
      split_faces_along_wire(e) if e.faces.empty? && !faces.empty?
      e
    end

    def split_edge(e, point)
      return nil unless e.valid? && point.on_line?(e.line)
      return e if point == e.start.position || point == e.end.position
      return nil unless (point - e.start.position).dot(point - e.end.position) < 0
      v = vertex(point)
      a, b = e.start, e.end
      first = edge(a, v); second = edge(v, b)
      e.faces.dup.each do |f|
        f.loops.each do |loop|
          vs = loop.vertices
          updated = []
          vs.each_with_index do |old, i|
            nxt = vs[(i+1)%vs.length]
            updated << old
            updated << v if (old == a && nxt == b) || (old == b && nxt == a)
          end
          loop.set_vertices(updated)
        end
        first.internal_faces << f unless first.faces.include?(f)
        second.internal_faces << f unless second.faces.include?(f)
      end
      [first, second].each { |x| x.soft = e.soft?; x.smooth = e.smooth?; x.hidden = e.hidden? }
      e.instance_variable_set(:@split_children,[first,second])
      a.internal_edges.delete(e); b.internal_edges.delete(e)
      @emap.delete([a.object_id,b.object_id].sort)
      @items.delete(e); e.internal_faces.clear; e.mark_deleted!
      second
    end

    # Copy supported mutable SketchUp attribute values by value. A split face
    # must not share a plugin's arrays, dictionaries or strings with its
    # sibling; copying the outer dictionary alone is insufficient.
    def copy_fragment_value(value, seen={})
      case value
      when Array
        return seen[value.object_id] if seen.key?(value.object_id)
        out=[];seen[value.object_id]=out
        value.each { |item| out << copy_fragment_value(item,seen) };out
      when Hash
        return seen[value.object_id] if seen.key?(value.object_id)
        out={};seen[value.object_id]=out
        value.each { |key,item| out[copy_fragment_value(key,seen)]=copy_fragment_value(item,seen) };out
      when String, Time, Geom::Point3d, Geom::Vector3d
        value.clone
      else
        value
      end
    end

    def copy_face_fragment_properties(source,fragment)
      return fragment if source.equal?(fragment)
      fragment.material=source.material;fragment.back_material=source.back_material
      fragment.uv_mapping=copy_fragment_value(source.uv_mapping)
      fragment.uv_mapping_back=copy_fragment_value(source.uv_mapping_back)
      fragment.layer=source.layer;fragment.hidden=source.hidden?
      fragment.casts_shadows=source.casts_shadows?;fragment.receives_shadows=source.receives_shadows?
      fragment.instance_variable_set(:@adapter_surface_token,source.instance_variable_get(:@adapter_surface_token))
      seen={}
      source.attribute_dictionaries.each do |dictionary|
        dictionary.each { |key,value| fragment.set_attribute(dictionary.name,key,copy_fragment_value(value,seen)) }
      end
      fragment
    end

    def split_faces_along_wire(new_edge)
      faces.dup.each do |face|
        next unless face.valid?
        if face.loops.length>1
          split_holed_face_along_wire(face,new_edge)
          next
        end
        next unless new_edge.vertices.all? { |v| v.position.on_plane?(face.plane) }
        middle = Geom.centroid(new_edge.vertices.map(&:position))
        next unless face.classify_point(middle) == Face::PointInside
        boundary = face.outer_loop.vertices
        wires = edges.select do |e|
          !e.faces.include?(face) && e.vertices.all? { |v| v.position.on_plane?(face.plane) } &&
            face.classify_point(Geom.centroid(e.vertices.map(&:position))) == Face::PointInside
        end
        starts = wires.flat_map(&:vertices).uniq & boundary
        links = Hash.new { |h,v| h[v] = [] }
        wires.each { |w| w.vertices.each { |v| links[v] << w.other_vertex(v) } }
        path = nil
        starts.each do |start|
          queue = [[start]]
          seen = {start => true}
          cursor = 0
          while cursor < queue.length
            chain = queue[cursor]
            cursor += 1
            current = chain.last
            if chain.length > 1 && boundary.include?(current)
              path = chain; break
            end
            links[current].each do |other|
              next if seen[other]
              seen[other] = true
              queue << chain + [other]
            end
          end
          break if path
        end
        next unless path
        i, j = boundary.index(path.first), boundary.index(path.last)
        ring = boundary.rotate(i)
        k = ring.index(path.last)
        loops = [ring[0..k] + path[1...-1].reverse, ring[k..-1] + [ring[0]] + path[1...-1]]
        fragment = add_face_raw(loops[1].map(&:position), loops[1])
        next unless fragment
        copy_face_fragment_properties(face,fragment)
        face.edges.each { |e| e.internal_faces.delete(face) }
        face.instance_variable_set(:@loops, [Loop.new(face, loops[0], true)])
        loops[0].each_with_index do |v,k|
          e = edge(v, loops[0][(k+1)%loops[0].length])
          e.internal_faces << face unless e.faces.include?(face)
        end
        @plane_index = nil
      end
    end
    def add_cline(a, b, _s = nil); c = ConstructionLine.new(a, b); c.parent_entities = self; @items << c; c; end
    def add_cpoint(p); c = ConstructionPoint.new(p); c.parent_entities = self; @items << c; c; end
    def add_text(t, p, v = nil); x = Text.new; x.text = t; x.point = p; x.vector = v; x.parent_entities = self; @items << x; x; end
    def add_dimension_linear(*_a); nil; end
    def add_dimension_radial(*_a); nil; end
    def add_section_plane(*_a); nil; end

    def add_edges(*pts)
      pts = pts.flatten(1) if pts.length == 1 && pts.first.is_a?(Array) && !pts.first.first.is_a?(Numeric)
      pts = pts.map { |p| Geom::Point3d.new(p.to_a) }
      created=pts.each_cons(2).flat_map { |a,b| respond_to?(:insert_segment) ? insert_segment(a,b) : [add_line(a,b)] }.compact
      result=[];pending=created.dup
      until pending.empty?
        e=pending.shift
        if e.valid?
          result << e
        else
          pending.unshift(*Array(e.instance_variable_get(:@split_children)))
        end
      end
      result.uniq
    end

    def add_curve(*pts)
      es = add_edges(*pts)
      c = Curve.new(es)
      es.each { |e| e.curve = c }
      es
    end

    def arc_points(center, xaxis, normal, radius, a0, a1, segs)
      center = Geom::Point3d.new(center.to_a)
      n = Geom::Vector3d.new(normal.to_a).normalize
      xa = Geom::Vector3d.new(xaxis.to_a)
      xa = (xa - n * xa.dot(n)).normalize
      ya = n.cross(xa).normalize
      (0..segs).map do |i|
        t = a0 + (a1 - a0) * i / segs.to_f
        center + xa * (radius * Math.cos(t)) + ya * (radius * Math.sin(t))
      end
    end

    def add_arc(center, xaxis, normal, radius, a0, a1, segs = 12)
      pts = arc_points(center, xaxis, normal, radius, a0, a1, segs)
      es = add_edges(pts)
      c = ArcCurve.new(es, Geom::Point3d.new(center.to_a), radius, Geom::Vector3d.new(normal.to_a).normalize,
                       Geom::Vector3d.new(xaxis.to_a).normalize, a0, a1)
      es.each { |e| e.curve = c }
      es
    end

    def add_circle(center, normal, radius, segs = 24)
      n = Geom::Vector3d.new(normal.to_a).normalize
      xa, = n.axes
      pts = arc_points(center, xa, n, radius, 0, 2 * Math::PI, segs)
      pts[-1] = pts[0]
      es = pts.each_cons(2).map { |a, b| add_line(a, b) }
      c = ArcCurve.new(es, Geom::Point3d.new(center.to_a), radius, n, xa, 0, 2 * Math::PI)
      es.each { |e| e.curve = c }
      es
    end

    def add_ngon(center, normal, radius, segs = 24); add_circle(center, normal, radius, segs); end

    def points_from_args(args)
      args = args.flatten(1) if args.length == 1 && args.first.is_a?(Array) && !args.first.first.is_a?(Numeric)
      args = args.first.edges if args.length == 1 && args.first.is_a?(Curve)
      if args.all? { |a| a.is_a?(Edge) }
        return Sweep.ordered_points(args).tap { |c| c.pop if c.length > 1 && c.first == c.last }
      end
      args.map { |p| Geom::Point3d.new(p.to_a) }
    end

    # Public add_face: SketchUp semantics (ground faces point down, a face
    # drawn inside a coplanar face carves a hole in it).
    def add_face(*args)
      pts = points_from_args(args)
      clean = []
      pts.each { |p| clean << p unless clean.last && clean.last == p }
      clean.pop while clean.length > 1 && clean.last == clean.first
      raise ArgumentError, "Points are not planar or duplicate" if clean.length < 3
      n = Geom.newell(clean)
      raise ArgumentError, "Points are collinear" unless n.valid?
      plane = Geom.fit_plane_to_points(clean)
      unless clean.all? { |p| p.distance_to_plane(plane) <= 0.01 }
        raise ArgumentError, "Points are not planar"
      end

      verts = clean.map { |p| vertex(p) }
      existing = verts.first.faces.find { |f| f.valid? && f.outer_loop.vertices.length == verts.length && (f.outer_loop.vertices - verts).empty? && f.loops.length == 1 }
      return existing if existing

      face = add_face_raw(clean, verts)
      # SketchUp: faces on the ground plane face down.
      if face.normal.z.abs > 0.9999 && clean.all? { |p| p.z.abs <= Geom::TOL } && face.normal.z > 0
        face.reverse!
      end
      carve(face)
      face
    end

    def add_face_raw(pts, verts = nil)
      verts ||= pts.map { |p| vertex(p) }
      verts = verts.each_with_object([]) { |v, a| a << v unless a.last.equal?(v) }
      verts.pop while verts.length > 1 && verts.last.equal?(verts.first)
      return nil if verts.uniq.length < 3 || !Geom.newell(verts.map(&:position)).valid?
      f = Face.new(self, verts)
      verts.each_with_index { |v, i| edge(v, verts[(i + 1) % verts.length]).internal_faces << f }
      @items << f
      index_plane(f) if @plane_index
      f
    end

    # Restrict carving to coplanar candidates. Catalog meshes contain thousands
    # of curved facets; scanning every earlier face made their build quadratic.
    # Moving vertices invalidates the index, and final exact plane tests remain
    # in carve, so the cache cannot change containment decisions.
    def plane_parts(face)
      n = face.normal.to_a
      axis = (0..2).max_by { |i| n[i].abs }
      n = n.map { |v| -v } if n[axis] < 0
      p = face.outer_loop.vertices.first.position.to_a
      [n, n.zip(p).sum { |a, b| a * b }]
    end

    def index_plane(face)
      n, d = plane_parts(face)
      key = n.map { |v| (v * 100_000).round } + [(d / Geom::TOL).round]
      (@plane_index[key] ||= []) << face
    end

    def coplanar_candidates(face)
      unless @plane_index
        @plane_index = {}
        faces.each { |f| index_plane(f) if f.valid? }
      end
      n, d = plane_parts(face)
      ranges = n.map { |v| [((v - 1e-8) * 100_000).round, ((v + 1e-8) * 100_000).round].uniq }
      dc = (d / Geom::TOL).round
      ranges[0].product(ranges[1], ranges[2], [dc - 1, dc, dc + 1]).flat_map { |k| @plane_index[k] || [] }
    end

    def carve(face)
      n = face.normal
      pts = face.outer_loop.points
      candidates = coplanar_candidates(face)
      candidates.each do |f|
        next if f.equal?(face) || !f.valid? || !f.normal.parallel?(n)
        next unless pts.first.on_plane?(f.plane)
        # new face inside f
        if f.contains_polygon_strict?(pts)
          f.add_hole(face.outer_loop.vertices.reverse)
          face.parent_face = f
          face.instance_variable_set(:@adapter_surface_token,f.instance_variable_get(:@adapter_surface_token))
          return
        end
      end
      # existing faces inside the new one
      candidates.each do |g|
        next if g.equal?(face) || !g.valid? || !g.normal.parallel?(n) || g.parent_face
        gp = g.outer_loop.points
        next unless gp.first.on_plane?(face.plane)
        if face.contains_polygon_strict?(gp)
          face.add_hole(g.outer_loop.vertices.reverse)
          g.parent_face = face
        end
      end
    end

    def erase_face_only(f)
      return unless f.valid?
      f.edges.each { |e| e.internal_faces.delete(f) }
      @items.delete(f)
      f.parent_face.remove_hole_matching(f.outer_loop.vertices) if f.parent_face && f.parent_face.valid? && false
      f.mark_deleted!
    end

    def erase_entities(*list)
      list.flatten.each do |e|
        next unless e && e.valid?
        case e
        when Face
          erase_face_only(e)
        when Edge
          next if merge_coplanar_faces(e)
          e.faces.dup.each { |f| erase_face_only(f) }
          e.start.internal_edges.delete(e); e.end.internal_edges.delete(e)
          @emap.delete([e.start.object_id, e.end.object_id].sort)
          @items.delete(e)
          e.mark_deleted!
        else
          @items.delete(e)
          e.definition.instances_list.delete(e) if e.respond_to?(:definition) && e.definition
          e.mark_deleted!
        end
      end
      nil
    end

    def merge_coplanar_faces(edge)
      fs = edge.faces.select(&:valid?)
      return false unless fs.length == 2 && fs[0].normal.parallel?(fs[1].normal)
      a, b = fs
      return false unless b.outer_loop.points.all? { |p| p.on_plane?(a.plane) }
      common = a.edges & b.edges
      boundary = (a.edges + b.edges).uniq - common
      links = Hash.new { |h,k| h[k] = [] }
      boundary.each { |e| e.vertices.each { |v| links[v] << e } }
      # Never replace a failed merge by erasing the two surface faces.
      raise 'Cannot merge an ambiguous coplanar boundary' unless links.values.all? { |es| es.length == 2 }
      unused = boundary.dup
      rings = []
      until unused.empty?
        first = unused.first.start
        current = first
        ring = []
        loop do
          ring << current
          step = links[current].find { |e| unused.include?(e) }
          raise 'Open boundary while merging coplanar faces' unless step
          unused.delete(step)
          current = step.other_vertex(current)
          break if current == first
        end
        rings << ring
      end
      n = a.normal
      rings.sort_by! { |vs| -Face.poly_area(vs.map(&:position)) }
      outer = rings.shift
      outer.reverse! if Geom.newell(outer.map(&:position)).dot(n) < 0
      (a.edges + b.edges).uniq.each { |e| e.internal_faces.delete(a); e.internal_faces.delete(b) }
      @items.delete(b); b.mark_deleted!
      a.instance_variable_set(:@loops, [Loop.new(a, outer, true)])
      outer.each_with_index { |v,i| edge(v,outer[(i+1)%outer.length]).internal_faces << a }
      rings.each { |vs| a.add_hole(vs) }
      common.each do |e|
        e.start.internal_edges.delete(e); e.end.internal_edges.delete(e)
        @emap.delete([e.start.object_id,e.end.object_id].sort)
        @items.delete(e); e.mark_deleted!
      end
      @plane_index = nil
      true
    end

    def clear!
      erase_entities(@items.dup)
      @vmap.clear; @emap.clear
      @plane_index = nil
      true
    end

    def transform_entities(t, *list)
      t = Geom::Transformation.coerce(t)
      expand=lambda do |value|
        if value.is_a?(Array) || value.is_a?(Selection) || value.is_a?(Entities)
          value.flat_map { |item| expand.call(item) }
        else
          [value]
        end
      end
      list = expand.call(list)
      verts = []
      list.each do |e|
        case e
        when Face, Edge then verts.concat(e.vertices)
        when Vertex then verts << e
        when Group, ComponentInstance then e.transformation = t * e.transformation
        end
      end
      verts.uniq.each { |v| v.move_to!(v.position.transform(t)) }
      true
    end

    def transform_by_vectors(list, vecs)
      list.each_with_index { |e, i| transform_entities(Geom::Transformation.translation(vecs[i]), e) }
      true
    end

    def add_group(*list)
      items=list.flatten.uniq.select { |e| e.respond_to?(:valid?) && e.valid? && e.parent_entities.is_a?(Entities) }
      owners=items.map(&:parent_entities).uniq
      transforms={}
      if owners.any? { |owner| !owner.equal?(self) }
        inverse=context_world_transform.inverse
        owners.each { |owner| transforms[owner]=inverse * owner.context_world_transform }
      else
        transforms[self]=Geom::Transformation.new
      end
      g = Group.new(model.definitions.new_group_definition)
      g.parent_entities = self
      @items << g
      unless items.empty?
        # Move faces before their edges. Erasing an edge while it still bounds
        # an unmoved face would erase that face, so shared parent edges remain.
        faces=items.grep(Face)
        boundary=faces.flat_map(&:edges).uniq
        faces.each { |e| e.parent_entities.move_into(e,g.entities,transforms.fetch(e.parent_entities)) }
        items.grep(Edge).each { |e| e.parent_entities.move_into(e,g.entities,transforms.fetch(e.parent_entities)) if e.valid? }
        (items-faces-items.grep(Edge)).each { |e| e.parent_entities.move_into(e,g.entities,transforms.fetch(e.parent_entities)) if e.valid? }
        boundary.each { |e| e.parent_entities.move_into(e,g.entities,transforms.fetch(e.parent_entities)) if e.valid? && !items.include?(e) }
      end
      g
    end

    # Crossing drawing contexts needs the actual placement of each definition.
    # A shared definition has no unique world transform unless the active path
    # identifies its instance; rejecting it is safer than moving the wrong copy.
    def context_world_transform(visited=[])
      return Geom::Transformation.new if @parent.is_a?(Model)
      raise ArgumentError,'Unsupported drawing context' unless @parent.is_a?(ComponentDefinition)
      raise ArgumentError,'Recursive drawing context' if visited.include?(@parent)
      instances=@parent.instances.select { |i| i.parent_entities.is_a?(Entities) }
      preferred=instances & Array(model.active_path)
      instance=preferred.length==1 ? preferred.first : instances.length==1 ? instances.first : nil
      raise ArgumentError,'Ambiguous shared drawing context' unless instance
      instance.parent_entities.context_world_transform(visited+[@parent]) * instance.transformation
    end

    def move_into(e, target, transform=Geom::Transformation.new)
      case e
      when Face
        reflect=transform.xaxis.dot(transform.yaxis.cross(transform.zaxis))<0
        points=e.outer_loop.points.map { |p| p.transform(transform) }
        points.reverse! if reflect
        f = target.add_face_raw(points)
        e.loops[1..-1].each do |l|
          hole=l.points.map { |p| p.transform(transform) };hole.reverse! if reflect
          f.add_hole(hole.map { |p| target.vertex(p) })
        end
        f.material = e.material; f.back_material = e.back_material
        f.layer=e.layer;f.hidden=e.hidden?;f.casts_shadows=e.casts_shadows?;f.receives_shadows=e.receives_shadows?
        f.uv_mapping=e.uv_mapping&.each_with_index&.map { |p,i| i.even? ? p.transform(transform) : p.clone }
        f.uv_mapping_back=e.uv_mapping_back&.each_with_index&.map { |p,i| i.even? ? p.transform(transform) : p.clone }
        e.attribute_dictionaries.each { |d| d.each { |k,v| f.set_attribute(d.name,k,v) } }
        erase_face_only(e)
      when Edge
        target.add_edges(e.start.position.transform(transform),e.end.position.transform(transform)).each do |copy|
          copy.material=e.material;copy.layer=e.layer;copy.hidden=e.hidden?
          copy.soft=e.soft?;copy.smooth=e.smooth?;copy.casts_shadows=e.casts_shadows?
          copy.receives_shadows=e.receives_shadows?
          e.attribute_dictionaries.each { |d| d.each { |k,v| copy.set_attribute(d.name,k,v) } }
        end
        erase_entities(e) if e.faces.empty?
      when Group, ComponentInstance
        @items.delete(e);e.transformation=transform*e.transformation
        e.parent_entities = target; target.raw_items << e
      end
    end

    def raw_items; @items; end

    def add_instance(defn, t)
      klass=defn.group? ? Group : ComponentInstance
      i = klass.new(defn, Geom::Transformation.coerce(t))
      i.parent_entities = self
      @items << i
      i
    end

    def fill_from_mesh(pm, _weld = true, _flags = 0, fm = nil, bm = nil)
      pm.polygons.each do |poly|
        pts = poly.map { |k| pm.point_at(k) }
        f = add_face_raw(pts)
        next unless f
        f.material = fm if fm
        f.back_material = bm if bm
        if fm && pm.uvs(true).any?
          f.uv_mapping = poly.flat_map { |k| [pm.point_at(k), pm.uv_at(k.abs, true)] }
        end
        if bm && pm.uvs(false).any?
          f.uv_mapping_back = poly.flat_map { |k| [pm.point_at(k), pm.uv_at(k.abs, false)] }
        end
        poly.each_with_index { |k, i| next unless k < 0; e = edge_between(f.outer_loop.vertices[i], f.outer_loop.vertices[(i + 1) % poly.length]); e.soft = true if e }
      end
      true
    end
    def add_faces_from_mesh(pm, flags = 0, fm = nil, bm = nil); fill_from_mesh(pm, true, flags, fm, bm); pm.count_polygons; end

    def weld(edges); edges; end

    def bounds_of_items(t = nil)
      bb = Geom::BoundingBox.new
      @items.each do |e|
        case e
        when Face, Edge then e.vertices.each { |v| bb.add(t ? v.position.transform(t) : v.position) }
        when Group, ComponentInstance
          tt = t ? t * e.transformation : e.transformation
          bb.add(e.definition.entities.bounds_of_items(tt))
        end
      end
      bb
    end
  end
end
