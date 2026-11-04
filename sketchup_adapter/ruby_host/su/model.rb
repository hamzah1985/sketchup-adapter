# SketchUp model-level emulation: groups, components, materials, layers,
# selection, options, observers, and the Sketchup module functions.
require "json"
require "fileutils"

GL_POINTS = 0x0000 unless defined?(GL_POINTS)
GL_LINES = 0x0001 unless defined?(GL_LINES)
GL_LINE_LOOP = 0x0002 unless defined?(GL_LINE_LOOP)
GL_LINE_STRIP = 0x0003 unless defined?(GL_LINE_STRIP)
GL_TRIANGLES = 0x0004 unless defined?(GL_TRIANGLES)
GL_QUADS = 0x0007 unless defined?(GL_QUADS)
GL_POLYGON = 0x0009 unless defined?(GL_POLYGON)

module Sketchup
  class Face
    def contains_polygon_strict?(pts)
      rings2, pp = project2d(pts)
      pp.all? { |q| Geom.point_in_polygon_2D(q, rings2[0], false) && !on_poly_border?(q, rings2[0]) } &&
        rings2[1..-1].none? { |h| pp.any? { |q| Geom.point_in_polygon_2D(q, h, true) } }
    end

    def reverse!
      @loops.each { |l| l.set_vertices(l.vertices.reverse) }
      fm = material; bm = back_material
      self.material = bm; self.back_material = fm
      m = @uv_mapping; @uv_mapping = @uv_mapping_back; @uv_mapping_back = m
      self
    end
  end

  class ComponentDefinition < Drawingelement
    attr_accessor :name, :description, :insertion_point
    attr_reader :entities, :instances_list, :behavior
    def initialize(name, group = false)
      super()
      @name = name; @description = ""; @group = group
      @entities = Entities.new(self)
      @instances_list = []
      @behavior = Behavior.new
    end
    def group?; @group; end
    def image?; false; end
    def internal?; false; end
    def hidden?; false; end
    def instances; @instances_list.select(&:valid?); end
    def count_instances; instances.length; end
    def count_used_instances; instances.length; end
    def bounds; @entities.bounds_of_items; end
    def invalidate_bounds; true; end
    def path; nil; end
    def guid; "def-#{entityID}"; end
    def refresh_thumbnail; true; end
    def save_as(_p); false; end
    def save_thumbnail(_p); false; end
    def live_component?; false; end
    def add_classification(*_a); true; end
    def erase!; Sketchup.active_model.definitions.remove(self); end
  end

  class Behavior
    attr_accessor :always_face_camera, :cuts_opening, :is2d, :snapto, :no_scale_mask, :shadows_face_sun, :no_scale_tool
    def initialize; @cuts_opening = false; @is2d = false; @snapto = 0; @no_scale_mask = 0; end
    def cuts_opening?; @cuts_opening; end
    def is2d?; @is2d; end
    def always_face_camera?; @always_face_camera; end
    def no_scale_tool?; @no_scale_tool; end
    def no_scale_mask?; @no_scale_mask; end
    def shadows_face_sun?; @shadows_face_sun; end
  end

  module Container
    attr_accessor :name, :locked, :glued_to, :description
    attr_reader :definition
    def transformation; @tr; end
    def transformation=(t); @tr = Geom::Transformation.coerce(t).clone; end
    def transform!(t); @tr = Geom::Transformation.coerce(t) * @tr; true; end
    def move!(t); self.transformation = t; true; end
    def locked?; @locked ? true : false; end
    def entities; @definition.entities; end
    def bounds
      bb = @definition.entities.bounds_of_items(@tr)
      bb
    end
    def local_bounds; @definition.entities.bounds_of_items; end
    def manifold?; true; end
    def volume; -1.0; end
    def guid; "inst-#{entityID}"; end
    def make_unique
      return self if @definition.instances.length <= 1
      nd = Sketchup.active_model.definitions.copy_definition(@definition, is_a?(Group))
      @definition.instances_list.delete(self)
      @definition = nd
      nd.instances_list << self
      self
    end
    def explode
      pe = @parent_entities
      return [] unless pe
      out = []
      unique_definition=is_a?(Group) && @definition.instances.length==1
      reflected=@tr.xaxis.dot(@tr.yaxis.cross(@tr.zaxis))<0
      @definition.entities.to_a.each do |e|
        case e
        when Sketchup::Face
          points=e.outer_loop.points.map { |p| p.transform(@tr) }
          holes=e.loops.drop(1).map { |l| l.points.map { |p| p.transform(@tr) } }
          # A reflection reverses polygon winding. Preserve the physical
          # front side (and cavity orientation) in the destination context.
          if reflected
            points.reverse!
            holes.each(&:reverse!)
          end
          previous=pe.faces
          f=previous.find do |candidate|
            next false unless candidate.loops.length==1+holes.length && Topology.same_loop?(candidate.outer_loop.points,points)
            remaining=candidate.loops.drop(1).map(&:points)
            holes.all? do |hole|
              index=remaining.index { |ring| Topology.same_loop?(ring,hole) }
              index && remaining.delete_at(index)
            end
          end
          reused=!!f
          f ||= pe.add_face(points)
          next unless f
          f.reverse! if !previous.include?(f) && f.normal.dot(Geom.newell(points))<0
          holes.each { |ring| f.add_hole(ring.map { |p| pe.vertex(p) }) } unless reused
          f.material = e.material || material
          f.back_material = e.back_material
          f.layer=e.layer;f.hidden=e.hidden?
          f.casts_shadows=e.casts_shadows?;f.receives_shadows=e.receives_shadows?
          e.attribute_dictionaries.each { |d| d.each { |k,v| f.set_attribute(d.name,k,v) } }
          out << f
        when Sketchup::Edge
          pe.add_edges(e.start.position.transform(@tr), e.end.position.transform(@tr)).each do |ne|
            ne.soft = e.soft?; ne.smooth = e.smooth?; ne.hidden = e.hidden?
            ne.casts_shadows=e.casts_shadows?;ne.receives_shadows=e.receives_shadows?
            ne.layer=e.layer;ne.material=e.material
            e.attribute_dictionaries.each { |d| d.each { |k,v| ne.set_attribute(d.name,k,v) } }
            out << ne
          end
        when Sketchup::Group, Sketchup::ComponentInstance
          if unique_definition
            # Preserve a nested instance's identity when its sole parent is
            # dissolved. References held by extensions must still designate
            # the instance which now belongs to the parent drawing context.
            @definition.entities.raw_items.delete(e)
            e.transformation=@tr * e.transformation
            e.parent_entities=pe;pe.raw_items << e
            ni=e
          else
            # A shared definition belongs to other placements as well.
            ni = pe.add_instance(e.definition, @tr * e.transformation)
            ni.name = e.name; ni.material = e.material
            e.attribute_dictionaries.each { |d| d.each { |k, v| ni.set_attribute(d.name, k, v) } } if e.attribute_dictionaries
          end
          out << ni
        end
      end
      erase!
      out.select(&:valid?).uniq
    end
    def copy
      parent=instance_variable_get(:@bridge_copy_parent) || @parent_entities
      if is_a?(Group)
        c=Group.new(@definition,@tr.clone)
        c.parent_entities=parent
        parent.raw_items << c
      else
        c = parent.add_instance(@definition, @tr)
      end
      c.material = material; c.name = name
      c.layer=layer;c.hidden=hidden?
      attribute_dictionaries&.each { |dictionary| dictionary.each { |key,value| c.set_attribute(dictionary.name,key,value) } }
      c
    end
    def to_component; self; end
    def equals?(o); false; end
    def intersect(o); nil; end
    def union(o); nil; end
    def subtract(o); nil; end
    def trim(o); nil; end
    def split(o); nil; end
    def outer_shell(o); nil; end
    def show_differences(*_a); nil; end
  end

  class Group < Drawingelement
    include Container
    def initialize(defn, tr = Geom::Transformation.new)
      super()
      @definition = defn; @tr = tr; @name = ""
      defn.instances_list << self
    end
    def to_component
      return nil unless valid? && @parent_entities
      # A group conversion replaces the instance, while retaining its
      # definition geometry and metadata. A shared group must first become
      # unique so other group placements retain their group semantics.
      make_unique
      @definition.instance_variable_set(:@group, false)
      component = @parent_entities.add_instance(@definition, @tr)
      %i[name material back_material layer hidden locked glued_to description
         casts_shadows receives_shadows].each do |key|
        component.public_send("#{key}=", public_send(key))
      end
      attribute_dictionaries&.each do |dict|
        dict.each { |key,value| component.set_attribute(dict.name,key,value) }
      end
      selection = model.selection
      selected = selection.include?(self)
      erase!
      if selected
        selection.remove(self)
        selection.add(component)
      end
      component
    end
  end

  class ComponentInstance < Drawingelement
    include Container
    def initialize(defn, tr)
      super()
      @definition = defn; @tr = tr; @name = ""
      defn.instances_list << self
    end
  end

  class DefinitionList
    include Enumerable
    def initialize; @defs = []; end
    def add(name)
      n = unique_name(name.to_s)
      d = ComponentDefinition.new(n)
      @defs << d
      d
    end
    def new_group_definition
      d = ComponentDefinition.new("Group##{@defs.length + 1}", true)
      @defs << d
      d
    end
    def copy_definition(src, group)
      d = group ? new_group_definition : add(src.name)
      copy_entities(src.entities, d.entities)
      src.attribute_dictionaries.each { |dict| dict.each { |k, v| d.set_attribute(dict.name, k, v) } } if src.attribute_dictionaries
      d
    end
    def copy_entities(from, to)
      from.to_a.each do |e|
        case e
        when Face
          f = to.add_face_raw(e.outer_loop.points)
          next unless f
          e.loops[1..-1].each { |l| f.add_hole(l.points.map { |p| to.vertex(p) }) }
          f.material = e.material; f.back_material = e.back_material
          f.uv_mapping = e.uv_mapping; f.uv_mapping_back = e.uv_mapping_back
          e.attribute_dictionaries.each { |dict| dict.each { |k, v| f.set_attribute(dict.name, k, v) } } if e.attribute_dictionaries
        when Edge
          ne = to.add_line(e.start.position, e.end.position)
          if ne
            ne.soft = e.soft?; ne.smooth = e.smooth?; ne.hidden = e.hidden?
          end
        when Group, ComponentInstance
          ni = if e.is_a?(Group)
                 g = to.add_group
                 g.definition.entities.clear!
                 copy_entities(e.definition.entities, g.definition.entities)
                 g.transformation = e.transformation
                 g
               else
                 to.add_instance(e.definition, e.transformation)
               end
          ni.name = e.name; ni.material = e.material; ni.layer = e.layer
          e.attribute_dictionaries.each { |dict| dict.each { |k, v| ni.set_attribute(dict.name, k, v) } } if e.attribute_dictionaries
        end
      end
    end
    def unique_name(base)
      return base unless self[base]
      i = 1
      i += 1 while self["#{base}##{i}"]
      "#{base}##{i}"
    end
    def [](k)
      return @defs[k] if k.is_a?(Integer)
      @defs.find { |d| d.name == k.to_s || d.guid == k.to_s }
    end
    def each(&b); @defs.dup.each(&b); end
    def length; @defs.length; end
    alias size length
    alias count length
    def remove(d); d.instances.each(&:erase!); @defs.delete(d); d.mark_deleted!; true; end
    def purge_unused; @defs.reject! { |d| d.instances.empty? && !d.group? && (d.mark_deleted! || true) }; self; end
    def load(path, *_a); raise IOError, "Loading .skp components is not supported in IngeTrazo (#{File.basename(path.to_s)})"; end
    def load_from_url(*_a); nil; end
    def add_observer(_o); true; end
    def remove_observer(_o); true; end
  end

  class Color
    attr_accessor :red, :green, :blue, :alpha
    NAMES = { "white" => [255, 255, 255], "black" => [0, 0, 0], "red" => [255, 0, 0], "green" => [0, 128, 0],
              "blue" => [0, 0, 255], "gray" => [128, 128, 128], "grey" => [128, 128, 128], "yellow" => [255, 255, 0],
              "silver" => [192, 192, 192], "orange" => [255, 165, 0], "brown" => [165, 42, 42] }
    def initialize(*a)
      a = a.first.to_a if a.length == 1 && (a.first.is_a?(Array) || a.first.is_a?(Color))
      if a.length == 1 && a.first.is_a?(String)
        s = a.first.strip
        if s =~ /\A#?([0-9a-f]{6})\z/i
          h = $1; a = [h[0, 2].hex, h[2, 2].hex, h[4, 2].hex]
        else
          a = NAMES[s.downcase] || [255, 255, 255]
        end
      elsif a.length == 1 && a.first.is_a?(Integer)
        v = a.first; a = [v & 255, (v >> 8) & 255, (v >> 16) & 255]
      end
      a = a.map { |v| v.is_a?(Float) && v <= 1.0 && a.all? { |w| w.is_a?(Float) } ? (v * 255).round : v.to_i }
      @red, @green, @blue = a[0] || 0, a[1] || 0, a[2] || 0
      @alpha = a[3] || 255
    end
    def to_a; [@red, @green, @blue, @alpha]; end
    def to_i; @red | (@green << 8) | (@blue << 16); end
    def blend(c, w); Color.new((0..3).map { |i| (to_a[i] * w + c.to_a[i] * (1 - w)).round }); end
    def ==(o); o.respond_to?(:to_a) && to_a == Color.new(o).to_a; end
    def self.names; NAMES.keys; end
    def to_s; "Color(#{to_a.join(', ')})"; end
  end

  class Texture < Entity
    attr_reader :filename, :image_width, :image_height
    attr_accessor :width, :height
    def initialize(path)
      super()
      @filename = path.to_s
      @image_width, @image_height = Sketchup.image_size(@filename)
      @width = @image_width.to_f
      @height = @image_height.to_f
      @width = 1.0 if @width <= 0
      @height = 1.0 if @height <= 0
    end
    def size=(v)
      if v.is_a?(Array)
        @width, @height = v[0].to_f, v[1].to_f
      else
        r = @image_height.to_f / [@image_width, 1].max
        @width = v.to_f; @height = v.to_f * r
      end
    end
    def average_color; Color.new(128, 128, 128); end
    def valid?; true; end
    def image_rep(*_a); nil; end
    def write(path, _c = false); FileUtils.cp(@filename, path) rescue false; true; end
  end

  class Material < Entity
    attr_accessor :name, :alpha, :colorize_type, :use_alpha
    attr_reader :color, :texture
    def initialize(name); super(); @name = name; @color = Color.new(255, 255, 255); @alpha = 1.0; @texture = nil; end
    def display_name; @name; end
    def color=(c); @color = c.nil? ? nil : Color.new(c); end
    def texture=(t)
      if t.nil?
        @texture = nil
      elsif t.is_a?(Array)
        @texture = Texture.new(t[0]); @texture.size = [t[1], t[2]]
      elsif t.is_a?(Texture)
        @texture = t
      else
        raise ArgumentError, "Texture file not found: #{t}" unless File.file?(t.to_s)
        @texture = Texture.new(t)
      end
    end
    def use_alpha?; @alpha < 1.0; end
    def materialType; @texture ? 1 : 0; end
    def owner_type; 0; end
    def save_as(_p); false; end
    def write_thumbnail(*_a); false; end
    def colorize_deltas; [0, 0, 0]; end
    def workflow; 0; end
  end

  class Materials
    include Enumerable
    attr_accessor :current
    def initialize; @list = []; end
    def add(name)
      n = unique_name(name.to_s)
      m = Material.new(n)
      @list << m
      m
    end
    def unique_name(base)
      return base unless self[base]
      i = 1
      i += 1 while self["#{base}#{i}"]
      "#{base}#{i}"
    end
    def [](k); k.is_a?(Integer) ? @list[k] : @list.find { |m| m.name == k.to_s }; end
    def each(&b); @list.dup.each(&b); end
    def length; @list.length; end
    alias size length
    alias count length
    def remove(m); m = self[m] unless m.is_a?(Material); @list.delete(m); m.mark_deleted! if m; true; end
    def purge_unused; self; end
    def load(_p); raise IOError, "Loading .skm is not supported"; end
    def add_observer(_o); true; end
    def remove_observer(_o); true; end
  end

  class Layer < Entity
    attr_accessor :name, :visible, :color, :folder, :line_style
    def initialize(n); super(); @name = n; @visible = true; end
    def visible?; @visible; end
    def display_name; @name; end
  end

  class Layers
    include Enumerable
    def initialize; @list = [Layer.new("Layer0")]; end
    def add(name); self[name] || (@list << Layer.new(name.to_s)).last; end
    alias add_layer add
    def [](k); k.is_a?(Integer) ? @list[k] : @list.find { |l| l.name == k.to_s }; end
    def each(&b); @list.dup.each(&b); end
    def length; @list.length; end
    alias size length
    alias count length
    def remove(l, _b = false); @list.delete(l); true; end
    def purge_unused; 0; end
    def each_folder; end
    def folders; []; end
    def add_observer(_o); true; end
    def remove_observer(_o); true; end
  end

  # Native models without saved camera scenes expose an empty Pages collection.
  class Pages
    include Enumerable
    def initialize; @observers=[]; end
    def each; return enum_for(:each) unless block_given?; self; end
    def size; 0; end
    alias length size
    def empty?; true; end
    def [](key); nil; end
    def selected_page; nil; end
    def add_observer(observer); @observers << observer unless @observers.include?(observer); true; end
    def remove_observer(observer); !!@observers.delete(observer); end
  end

  class Selection
    include Enumerable
    def initialize(model); @model = model; @list = []; @obs = []; end
    def each(&b); @list.dup.each(&b); end
    def to_a; @list.dup; end
    def length; @list.length; end
    alias size length
    alias count length
    alias nitems length
    def empty?; @list.empty?; end
    def first; @list.first; end
    def [](i); @list[i]; end
    def include?(e); @list.include?(e); end
    alias contains? include?
    alias is_selected? include?
    def single_object?; @list.length == 1; end
    def clear; @list.clear; notify(:onSelectionCleared); self; end
    def add(*e); e.flatten.each { |x| @list << x unless @list.include?(x) }; notify(:onSelectionBulkChange); self; end
    def remove(*e); e.flatten.each { |x| @list.delete(x) }; notify(:onSelectionBulkChange); self; end
    alias delete remove
    def toggle(*e); e.flatten.each { |x| @list.include?(x) ? @list.delete(x) : @list << x }; notify(:onSelectionBulkChange); self; end
    def invert; self; end
    def set_silently(list); @list = list.dup; end
    def add_observer(o); @obs << o unless @obs.include?(o); true; end
    def remove_observer(o); @obs.delete(o); true; end
    def notify(ev)
      return if @silent
      @obs.dup.each do |o|
        begin
          o.send(ev, self) if o.respond_to?(ev)
        rescue StandardError => e
          Sketchup.log_exc("selection observer", e)
        end
      end
    end
    def silently; @silent = true; yield; ensure @silent = false; end
  end

  class OptionsProvider
    include Enumerable
    def initialize(h); @h = h; end
    def [](k); @h[k.to_s]; end
    def []=(k, v); @h[k.to_s] = v; end
    def keys; @h.keys; end
    def each(&b); @h.each(&b); end
    def each_key(&b); @h.each_key(&b); end
    def key?(k); @h.key?(k.to_s); end
    alias has_key? key?
    def add_observer(o); (@obs ||= []) << o unless (@obs ||= []).include?(o); true; end
    def remove_observer(o); (@obs ||= []).delete(o); true; end
    def name; "UnitsOptions"; end
    # IngeTrazo changed a value: store it and tell observers, like SketchUp.
    def change(k, v)
      return if @h[k.to_s] == v
      @h[k.to_s] = v
      (@obs || []).dup.each do |o|
        begin
          o.onOptionsProviderChanged(self, k.to_s) if o.respond_to?(:onOptionsProviderChanged)
        rescue StandardError => e
          Sketchup.log_exc("options observer", e)
        end
      end
    end
  end

  class OptionsManager
    def initialize
      @p = {
        "UnitsOptions" => OptionsProvider.new("LengthUnit" => 2, "LengthFormat" => 0, "LengthPrecision" => 0,
                                              "LengthSnapEnabled" => false, "SuppressUnitsDisplay" => false,
                                              "ForceInchDisplay" => false, "AreaUnit" => 2, "VolumeUnit" => 2),
        "PageOptions" => OptionsProvider.new({}),
        "PrintOptions" => OptionsProvider.new({}),
        "SlideshowOptions" => OptionsProvider.new({}),
        "NamedOptions" => OptionsProvider.new({})
      }
    end
    def [](k); @p[k.to_s] || (@p[k.to_s] = OptionsProvider.new({})); end
    def each(&b); @p.values.each(&b); end
    def keys; @p.keys; end
  end

  class Camera
    attr_accessor :eye, :target, :up, :perspective, :fov, :aspect_ratio, :height
    def initialize(eye = [-1000,-2000,1000], target = [0,0,0], up = [0,0,1], perspective = true, fov = 35.0)
      set(eye, target, up)
      @perspective = !!perspective
      @fov, @aspect_ratio, @height = fov.to_f, 0.0, 1000.0
    end
    def direction; (@target - @eye).normalize; end
    def perspective?; @perspective; end
    def xaxis; direction.cross(@up).normalize; end
    def yaxis; xaxis.cross(direction).normalize; end
    def zaxis; direction; end
    def set(eye, target, up)
      @eye, @target = [eye,target].map { |p| Geom::Point3d.new(p.to_a) }
      @up = Geom::Vector3d.new(up.to_a)
      self
    end
    def is_2d?; false; end
    def fov_is_height?; true; end
  end

  class View
    attr_accessor :camera
    def initialize
      @camera = Camera.new
      @cursor = {}
      @screen_point_ids = {}
      @overlay = []
      @drawing_color = Color.new(0, 0, 0)
      @line_width = 1
      @line_stipple = ""
    end
    def add_observer(observer)
      @view_observers ||= []
      return false if @view_observers.include?(observer)
      @view_observers << observer
      true
    end
    def remove_observer(observer)
      !!(@view_observers && @view_observers.delete(observer))
    end
    def native_camera?; !!@native_camera; end
    def apply_native_camera(values)
      return unless values.is_a?(Hash)
      eye, target, up = values.values_at('eye', 'target', 'up')
      size = values['viewport_size']
      vectors = [eye, target, up]
      return unless vectors.all? { |v| v.is_a?(Array) && v.length == 3 && v.all? { |x| x.is_a?(Numeric) && x.finite? } }
      return unless size.is_a?(Array) && size.length == 2 && size.all? { |n| n.is_a?(Numeric) && n.finite? && n > 0 }
      fov, height = values.values_at('fov', 'height')
      return unless fov.is_a?(Numeric) && fov.finite? && fov > 0 && fov < 180 && height.is_a?(Numeric) && height.finite? && height > 0
      perspective = values['perspective']
      return unless perspective == true || perspective == false
      return if @native_camera == values
      @camera.set(eye.map { |n| n / Host::INCH }, target.map { |n| n / Host::INCH }, up)
      @camera.perspective, @camera.fov, @camera.height = perspective, fov.to_f, height.to_f / Host::INCH
      @camera.aspect_ratio = size[0].to_f / size[1]
      @cursor['viewport_size'] = size.map(&:to_i)
      @native_camera = values
      (@view_observers || []).dup.each do |observer|
        begin
          observer.onViewChanged(self) if observer.respond_to?(:onViewChanged)
        rescue StandardError => error
          Sketchup.log_exc('view observer', error)
        end
      end
      nil
    end
    def invalidate; Bridge.notify("invalidate"); self; end
    def refresh; self; end
    def model; Sketchup.active_model; end
    def vpwidth; (@cursor["viewport_size"] || (@native_camera || {})['viewport_size'] || [1200, 800])[0].to_i; end
    def vpheight; (@cursor["viewport_size"] || (@native_camera || {})['viewport_size'] || [1200, 800])[1].to_i; end
    def pixels_to_model(px, pt)
      p = Geom::Point3d.new(pt.to_a)
      a = screen_coords(p)
      b = screen_coords(p + Geom::Vector3d.new(1, 0, 0))
      c = screen_coords(p + Geom::Vector3d.new(0, 1, 0))
      scales = [[a.x - b.x, a.y - b.y], [a.x - c.x, a.y - c.y]].map { |d| Math.hypot(*d) }.select { |d| d > 1e-6 }
      scales.empty? ? px.to_f * 0.5 : px.to_f / scales.max
    end
    def screen_coords(p)
      a = @cursor["mvp"]
      return Geom::Point3d.new(0, 0, 0) unless a && a.length >= 16
      # SketchUp points are inches; the native camera matrix uses metres.
      # World-space overlays and committed geometry use the same conversion.
      x, y, z = p.to_a.map { |value| value.to_f * 0.0254 }
      cx = a[0] * x + a[4] * y + a[8] * z + a[12]
      cy = a[1] * x + a[5] * y + a[9] * z + a[13]
      cz = a[2] * x + a[6] * y + a[10] * z + a[14]
      cw = a[3] * x + a[7] * y + a[11] * z + a[15]
      return Geom::Point3d.new(0, 0, 0) if cw.abs < 1e-12
      sx = (cx / cw + 1.0) * vpwidth / 2.0
      sy = (1.0 - cy / cw) * vpheight / 2.0
      out = Geom::Point3d.new(sx, sy, cz / cw)
      @screen_point_ids[out.object_id] = true
      out
    end
    def zoom(item = nil)
      if item.is_a?(Numeric)
        @camera.height /= item.to_f if item > 0
      elsif item && item.respond_to?(:bounds)
        bounds = item.bounds
        size = [bounds.width,bounds.height,bounds.depth].max.to_f
        if size > 0
          center = bounds.center
          direction = @camera.direction.reverse
          @camera.set(center.offset(direction,size*1.8),center,@camera.up)
          @camera.height = size*1.3
        end
      end
      self
    end
    def zoom_extents; zoom(Sketchup.active_model); end
    def lock_inference(*_a); nil; end
    def tooltip=(_t); end
    def inputpoint(*_a); InputPoint.new(@cursor, @pick_face); end
    def pick_helper; PickHelper.new(@pick_target, @pick_face, @cursor["xform"]); end
    def pickray(*_a)
      ray = @cursor["ray"]
      return nil unless ray && ray.length == 2
      [Geom::Point3d.new(ray[0]), Geom::Vector3d.new(ray[1])]
    end
    def draw(mode, *points)
      points=draw_point_arguments(points)
      capture_draw(mode, points, "world") unless points.empty?
      self
    end
    def draw2d(mode, *points)
      points=draw_point_arguments(points)
      capture_draw(mode, points, "screen") unless points.empty?
      self
    end
    def draw_lines(*points)
      previous=@drawing_color
      color=points.pop if points.last.is_a?(String) || points.last.is_a?(Color)
      self.drawing_color=color if color
      draw(GL_LINES,*points)
    ensure
      @drawing_color=previous
    end
    alias draw_line draw_lines
    def draw_polyline(*points); draw(GL_LINE_STRIP,*points); end
    def draw_points(points, size = 6, style = 3, color = nil)
      old = @drawing_color
      self.drawing_color = color if color
      item = capture_draw(GL_POINTS, draw_point_arguments([points]), "world")
      item["point_size"] = size.to_f if item
      item["point_style"] = style.to_i if item
      @drawing_color = old
      self
    end
    def drawing_color; @drawing_color; end
    def drawing_color=(c); @drawing_color = c; end
    def line_width; @line_width; end
    def line_width=(w); @line_width = w.to_f; end
    def line_stipple; @line_stipple; end
    def line_stipple=(s); @line_stipple = s.to_s; end
    def set_color_from_line(*_a); end
    def draw_text(point, text, *_a)
      capture_draw(nil, [point], @screen_point_ids[point.object_id] ? "screen" : "world", text.to_s)
    end
    def write_image(*args)
      opts = args.first.is_a?(Hash) ? args.first : {filename:args[0],width:args[1],height:args[2]}
      path = opts[:filename] || opts['filename']
      return false unless path
      groups = Sketchup.active_model.entities.to_a.select { |e| (e.is_a?(Group) || e.is_a?(ComponentInstance)) && e.valid? && !e.hidden? }
      response = Bridge.call('write_image','path'=>File.expand_path(path.to_s),
        'width'=>(opts[:width] || opts['width'] || vpwidth),
        'height'=>(opts[:height] || opts['height'] || vpheight),
        'groups'=>groups.map { |g| Host.export_container(g) },
        'camera'=>{'eye'=>Host.m(@camera.eye),'target'=>Host.m(@camera.target),
          'up'=>@camera.up.to_a,'perspective'=>@camera.perspective?,'fov'=>@camera.fov,
          'height'=>@camera.height*Host::INCH})
      response.is_a?(Hash) && response['ok']
    end
    def show_frame(*_a); self; end
    def average_refresh_time; 0.01; end
    def set_cursor_data(data, target = nil)
      @cursor = data || {}
      @cursor["x"] = (@cursor["screen"] || [0, 0])[0].to_f
      @cursor["y"] = (@cursor["screen"] || [0, 0])[1].to_f
      @pick_target = target
      @screen_point_ids.clear
      # A multi-step tool can retain this Face while a room is locked.
      # Rebuilding an unchanged cursor surface on Enter left the tool cutting
      # its old private Face while sync inspected a new, untouched one.
      signature = @cursor['face_token'] && JSON.generate(
        [@cursor['face_token'],@cursor['face'],@cursor['holes'],@cursor['normal']])
      reuse_surface = signature && signature == @surface_source &&
                      @pick_definition && @pick_face && @pick_face.valid?
      unless reuse_surface
        @pick_face = nil
        @pick_definition = nil
        @surface_baseline = nil
      end
      pts = Array(@cursor["face"]).map { |p| Geom::Point3d.new(p) }
      if pts.length >= 3 && !reuse_surface
        # This private entities collection gives extensions a real Face to
        # inspect without adding cursor proxies to the document model.
        @pick_definition = ComponentDefinition.new('Native cursor surface')
        @pick_entities = @pick_definition.entities
        # Operation rollback must also cover edits to this private surface.
        Sketchup.active_model.instance_variable_set(:@bridge_pick_definition, @pick_definition)
        @pick_face = @pick_entities.add_face_raw(pts)
        Array(@cursor["holes"]).each do |ring|
          verts = ring.map { |p| @pick_entities.vertex(Geom::Point3d.new(p)) }
          @pick_face.add_hole(verts) if @pick_face
        end
      end
      if @pick_face && @cursor["normal"]
        n = @pick_face.normal
        expected = Geom::Vector3d.new(@cursor["normal"])
        @pick_face.reverse! if n.dot(expected) < 0
      end
      unless reuse_surface
        @surface_source = signature
        @surface_baseline = @pick_definition && JSON.generate(Host.export_definition(@pick_definition)['protos'][0]['faces'])
      end
      self
    end
    def native_surface_patch
      return nil unless @cursor['face_token'] && @pick_definition && @surface_baseline
      faces = Host.export_definition(@pick_definition)['protos'][0]['faces']
      stamp = JSON.generate(faces)
      return nil if stamp == @surface_baseline
      @surface_baseline = stamp
      {'token'=>@cursor['face_token'],'faces'=>faces}
    end
    def begin_overlay_capture; @overlay = []; end
    def take_overlay; out = @overlay; @overlay = []; out; end
    def projection_data; @cursor["mvp"]; end
    private
    def draw_point_arguments(arguments)
      arguments=arguments.compact
      if arguments.length==1 && arguments.first.is_a?(Array) &&
          (arguments.first.empty? || !arguments.first.all? { |item| item.is_a?(Numeric) })
        arguments.first
      else
        arguments
      end
    end
    def capture_draw(mode, points, space, text = nil)
      names = { GL_POINTS => "points", GL_LINES => "lines", GL_LINE_LOOP => "line_loop",
                GL_LINE_STRIP => "line_strip", GL_TRIANGLES => "triangles",
                GL_QUADS => "quads", GL_POLYGON => "polygon" }
      pts = points.map do |p|
        coordinates=p.respond_to?(:to_a) ? p.to_a : Array(p)
        raise ArgumentError,'Expected two or three finite point coordinates' unless
          (2..3).cover?(coordinates.length) && coordinates.all? { |v| v.is_a?(Numeric) && v.finite? }
        coordinates.map(&:to_f)
      end
      item = { "mode" => (text ? "text" : names[mode] || "line_strip"),
               "space" => space, "points" => pts,
               "color" => Color.new(@drawing_color).to_a,
               "width" => @line_width, "stipple" => @line_stipple }
      item["text"] = text if text
      @overlay << item
      item
    end
  end

  class InputPoint
    def initialize(cursor = {}, face = nil)
      @cursor = cursor.is_a?(Hash) ? cursor.dup :
        (cursor ? {"point"=>cursor.to_a.dup,"valid"=>true} : {})
      @face = face
    end
    def position; Geom::Point3d.new(@cursor["point"] || [0, 0, 0]); end
    def valid?; !!@cursor["valid"]; end
    def pick(view, *_args)
      copy!(view.inputpoint)
      valid?
    end
    def face; @face; end
    def edge
      return nil unless @face
      @face.edges.min_by do |e|
        a, b = e.start.position, e.end.position
        ab = b - a
        l2 = ab.dot(ab)
        t = l2 < 1e-18 ? 0.0 : [[(position - a).dot(ab) / l2, 0.0].max, 1.0].min
        position.distance(a + ab * t)
      end
    end
    def vertex
      return nil unless @face && @cursor["snap"] == "endpoint"
      @face.vertices.min_by { |v| v.position.distance(position) }
    end
    def transformation; Geom::Transformation.coerce(@cursor["xform"] || Geom::Transformation.new); end
    def degrees_of_freedom; 3; end
    def draw(*_a); end
    def display?; valid?; end
    def clear; @cursor = {}; @face = nil; self; end
    def copy!(other)
      raise ArgumentError, 'Expected an InputPoint' unless other.is_a?(InputPoint)
      @cursor = other.instance_variable_get(:@cursor).dup
      @cursor['point'] = @cursor['point'].dup if @cursor['point']
      @face = other.face
      self
    end
    def tooltip; ""; end
  end

  class PickHelper
    def initialize(target = nil, face = nil, xform = nil)
      @target, @face, @xform = target, face, Geom::Transformation.coerce(xform || Geom::Transformation.new)
    end
    def do_pick(*_a); count.positive?; end
    def best_picked; @face || @target; end
    def all_picked; [@face || @target].compact; end
    def leaf_at(i); i.to_i == 0 ? best_picked : nil; end
    def picked_face; @face; end
    def picked_edge; @target if @target.is_a?(Sketchup::Edge); end
    def count; (@face || @target) ? 1 : 0; end
    def path_at(i); i.to_i == 0 ? [@target, @face].compact : nil; end
    def transformation_at(i); i.to_i == 0 ? @xform : nil; end
    def depth_at(i); i.to_i == 0 && count.positive? ? 0.0 : nil; end
  end

  class Tools
    attr_reader :active_tool_id, :active_tool_name
    def initialize; @obs = []; @active_tool_id = 21022; @active_tool_name = "SelectionTool"; @stack = []; end
    def add_observer(o); @obs << o; true; end
    def remove_observer(o); @obs.delete(o); true; end
    def observers; @obs; end
    def push_tool(t); @stack << t; t.activate if t.respond_to?(:activate); true; end
    def pop_tool; @stack.pop; true; end
    def active_tool; @stack.last; end
    def set_active(id, name)
      @active_tool_id = id; @active_tool_name = name
      @obs.dup.each do |o|
        begin
          o.onActiveToolChanged(self, name, id) if o.respond_to?(:onActiveToolChanged)
        rescue StandardError => e
          Sketchup.log_exc("tools observer", e)
        end
      end
    end
  end

  # The extension API uses overlays for non-interactive previews which remain
  # visible while the user's current tool changes. IngeTrazo renders the draw
  # calls captured by View, so this adapter preserves overlay lifecycle and
  # sends their geometry through the existing overlay protocol.
  class Overlay
    attr_reader :overlay_id, :name
    attr_accessor :description

    def initialize(overlay_id, name, *args, **kwargs)
      options = args.last.is_a?(Hash) ? args.last : {}
      options = options.merge(kwargs)
      @overlay_id = overlay_id.to_s
      @name = name.to_s
      @description = options[:description] || options["description"] || ""
      @enabled = false
      @valid = true
      @started = false
    end

    def enabled?; @enabled; end
    def enabled=(value)
      value = !!value
      return value if value == @enabled
      @enabled = value
      if value
        @started = true
        start if respond_to?(:start)
      elsif @started
        @started = false
        stop if respond_to?(:stop)
      end
      value
    rescue StandardError
      @enabled = false if value
      @started = false if value
      raise
    end

    def valid?; @valid; end
    def invalidate!; @valid = false; @enabled = false; @started = false; end
  end

  class Overlays
    include Enumerable

    def initialize(model)
      @model = model
      @items = []
    end

    def add(overlay)
      return false unless overlay.is_a?(Sketchup::Overlay) && overlay.valid?
      return false if @items.include?(overlay)
      @items << overlay
      true
    end

    def remove(overlay)
      return false unless @items.delete(overlay)
      if overlay.enabled?
        overlay.enabled = false
      elsif overlay.respond_to?(:stop)
        overlay.stop
      end
      overlay.invalidate!
      @model.active_view.invalidate
      true
    end

    def each(&block); @items.each(&block); end
    def to_a; @items.dup; end
    def include?(overlay); @items.include?(overlay); end
    def [](index); @items[index]; end
    def count; @items.count; end
    alias length count
    alias size count
    def empty?; @items.empty?; end
  end

  class RenderingOptions < OptionsProvider
    # One coarse notification represents a native style snapshot assignment.
    # Exact numeric parity with every SketchUp version is unverified.
    ROPAssign = 0
    def apply_native_snapshot(values)
      return unless values.is_a?(Hash)
      changed = false
      %w[BackgroundColor SkyColor GroundColor FaceFrontColor FaceBackColor].each do |key|
        rgb = values[key]
        next unless rgb.is_a?(Array) && rgb.length == 3 && rgb.all? { |n| n.is_a?(Numeric) && n.finite? && n.between?(0, 255) }
        color = Color.new(rgb.map(&:round))
        next if @h[key].is_a?(Color) && @h[key].to_a == color.to_a
        @h[key] = color
        changed = true
      end
      return unless changed
      (@obs || []).dup.each do |observer|
        begin
          observer.onRenderingOptionsChanged(self, ROPAssign) if observer.respond_to?(:onRenderingOptionsChanged)
        rescue StandardError => error
          Sketchup.log_exc('rendering options observer', error)
        end
      end
      nil
    end
  end
  class ShadowInfo < OptionsProvider; end

  class Model < Entity
    attr_reader :entities, :definitions, :materials, :layers, :selection, :options, :active_view, :tools, :overlays,
                :rendering_options, :shadow_info
    attr_accessor :active_path, :title, :path, :description
    def initialize
      super()
      @entities = Entities.new(self)
      @definitions = DefinitionList.new
      @materials = Materials.new
      @layers = Layers.new
      @selection = Selection.new(self)
      @options = OptionsManager.new
      @active_view = View.new
      @tools = Tools.new
      @overlays = Overlays.new(self)
      @rendering_options = RenderingOptions.new({'FaceFrontColor'=>Color.new(255,255,255),
        'FaceBackColor'=>Color.new(128,128,255),'EdgeColor'=>Color.new(0,0,0)})
      @shadow_info = ShadowInfo.new({})
      @title = "IngeTrazo"
      @description = ""
      @path = ""
      @ops = []
      @observers = []
      @active_path = nil
    end
    def model; self; end
    def name; @title; end
    def name=(value); @title=value.to_s; end
    def active_entities; @entities; end
    def active_layer; @layers[0]; end
    def active_layer=(_l); end
    def edit_transform; Geom::Transformation.new; end
    def valid?; true; end
    def guid; "ingetrazo-model"; end
    def modified?; false; end
    def pages; @pages ||= Pages.new; end
    def styles; []; end
    def number_faces; 0; end
    def bounds; @entities.bounds_of_items; end
    def georeferenced?
      result=Bridge.call('geolocation','action'=>'status')
      result.is_a?(Hash) && result['ok'] && result['georeferenced'] == true
    end
    def latlong_to_point(values)
      input=Array(values)
      raise ArgumentError,'Expected longitude, latitude and optional altitude' unless (2..3).cover?(input.length)
      result=Bridge.call('geolocation','action'=>'to_local','values'=>input.map { |value| Float(value) })
      raise(result.is_a?(Hash) ? result['error'].to_s : 'Geolocation service is unavailable') unless result.is_a?(Hash) && result['ok']
      Geom::Point3d.new(result['values'].map { |value| value.to_f / Host::INCH })
    end
    def point_to_latlong(point)
      coordinates=Geom::Point3d.new(point.to_a).to_a.map { |value| value * Host::INCH }
      result=Bridge.call('geolocation','action'=>'to_geodetic','values'=>coordinates)
      raise(result.is_a?(Hash) ? result['error'].to_s : 'Geolocation service is unavailable') unless result.is_a?(Hash) && result['ok']
      Geom::Point3d.new(result['values'])
    end
    def start_operation(*_a); @ops << true; true; end
    def commit_operation; @ops.pop; true; end
    def abort_operation; @ops.pop; true; end
    def add_observer(o); @observers << o; true; end
    def remove_observer(o); @observers.delete(o); true; end
    def observers; @observers; end
    def place_component(defn, _repeat = false)
      Bridge.place_component(defn)
      true
    end
    def commit_placement(defn, xf)
      inst = @entities.add_instance(defn, xf)
      inst
    end
    def classifications; []; end
    def export(*_a); false; end
    def save(*_a); false; end
    def close_active; false; end
    def raytest(ray, _wysiwyg = false)
      return nil unless ray && ray.length >= 2
      view = @active_view
      face = view.pick_helper.best_picked
      return nil unless face.is_a?(Sketchup::Face)
      origin = Geom::Point3d.new(ray[0].to_a)
      direction = Geom::Vector3d.new(ray[1].to_a)
      normal = face.normal
      den = normal.dot(direction)
      return nil if den.abs < 1e-12
      plane = face.plane
      t = -(plane[0] * origin.x + plane[1] * origin.y + plane[2] * origin.z + plane[3]) / den
      return nil if t < 0
      point = origin + direction * t
      return nil unless [1, 4].include?(face.classify_point(point))
      [point, view.pick_helper.path_at(0) || [face]]
    rescue StandardError
      nil
    end
    def select_tool(tool); Host.select_tool(tool); true; end
    def set_attribute(d, k, v); super; end
    def find_entity_by_id(id); ObjectSpace.each_object(Entity).find { |e| e.entityID == id }; end
    def find_entity_by_persistent_id(*ids); ids.map { |id| find_entity_by_id(id) }; end
    def instance_path_from_pid_path(*_a); nil; end
    def line_styles; []; end
    def axes; nil; end
  end

  def self.log_exc(where, e)
    $stderr.puts "SketchUp adapter host [#{where}] #{e.class}: #{e.message}"
    $stderr.puts e.backtrace.first(5).join("\n") if e.backtrace
  end

  @model = Model.new
  @defaults_path = nil
  @defaults = nil
  @observers = []

  class << self
    attr_accessor :plugins_dir
    def active_model; @model; end
    def reset_model!; @model = Model.new; end
    def version; "26.0.0"; end
    def version_number; 2_600_000_000; end
    def platform; :platform_win; end
    def is_pro?; true; end
    def debug_mode?; false; end
    def is_online; false; end
    def os_language; "en-US"; end
    def get_locale; "en-US"; end
    def temp_dir; Dir.respond_to?(:tmpdir) ? Dir.tmpdir : ENV["TEMP"] || "."; end
    def focus; Bridge.notify("focus_model"); true; end
    def status_text; @status_text.to_s; end
    def status_text=(t)
      @status_text=t.to_s
      tool=Host.active_tool_id if defined?(Host) && Host.respond_to?(:active_tool_id)
      Bridge.notify('status','text'=>@status_text,'tool'=>tool)
    end
    def set_status_text(t = "", pos = nil)
      if pos == 1 || pos == 2
        Bridge.notify('vcb', 'slot'=>pos, 'text'=>t.to_s)
      else
        self.status_text = t
      end
    end
    def vcb_label=(t); set_status_text(t, 1); end
    def vcb_value=(t); set_status_text(t, 2); end
    def add_observer(o); @observers << o; true; end
    def remove_observer(o); @observers.delete(o); true; end
    def register_extension(ext, _load); ext.load_now; true; end
    def register_importer(importer)
      @importers ||= []
      @importers << importer unless @importers.any? { |i| i.id == importer.id }
      true
    end
    def undo; Bridge.notify("undo"); end
    def send_action(a); Bridge.notify("action", "name" => a.to_s); true; end
    def find_support_file(name, dir = "")
      p = File.join(@plugins_dir.to_s, dir.to_s, name.to_s)
      File.exist?(p) ? p : nil
    end
    def resize_viewport(*_a); end
    def file_new; end
    def open_file(*_a); false; end
    def extensions; []; end
    def require(path)
      path = path.to_s.sub(/\.rb[es]?\z/, "")
      full = File.expand_path(path, @plugins_dir)
      Kernel.require(full)
    end
    def load(path); Kernel.load(File.expand_path(path.to_s, @plugins_dir)); end

    def defaults_path
      @defaults_path ||= begin
        base = ENV["APPDATA"] || File.join(Dir.home, ".local", "share")
        dir = File.join(base, "ingetrazo", "sketchup_adapter")
        FileUtils.mkdir_p(dir)
        File.join(dir, "defaults.json")
      end
    end
    def defaults_data
      @defaults ||= (File.file?(defaults_path) ? (JSON.parse(File.read(defaults_path, encoding: "UTF-8")) rescue {}) : {})
    end
    def read_default(section, key, default = nil)
      v = (defaults_data[section.to_s] || {})[key.to_s]
      v.nil? ? default : v
    end
    def write_default(section, key, value)
      (defaults_data[section.to_s] ||= {})[key.to_s] = value
      File.write(defaults_path, JSON.generate(defaults_data))
      true
    end

    # PNG/JPEG/BMP pixel size without an image library.
    def image_size(path)
      data = File.binread(path.to_s, 64 * 1024) rescue nil
      return [256, 256] unless data
      if data[0, 8] == "\x89PNG\r\n\x1A\n".b
        return data[16, 8].unpack("NN")
      elsif data[0, 2] == "BM".b
        w, h = data[18, 8].unpack("l<l<")
        return [w, h.abs]
      elsif data[0, 2] == "\xFF\xD8".b
        i = 2
        while i < data.length - 9
          if data.getbyte(i) != 0xFF
            i += 1
            next
          end
          marker = data.getbyte(i + 1)
          len = data[i + 2, 2].unpack1("n")
          if [0xC0, 0xC1, 0xC2].include?(marker)
            h, w = data[i + 5, 4].unpack("nn")
            return [w, h]
          end
          i += 2 + len
        end
      end
      [256, 256]
    end
  end

  # Observer base classes (the plugin subclasses these).
  class EntityObserver; end
  class EntitiesObserver; end
  class SelectionObserver; end
  class ModelObserver; end
  class ToolsObserver; end
  class AppObserver; end
  class OptionsProviderObserver; end
  class RenderingOptionsObserver; end
  # The upstream builders use this API for locale-aware length labels.
  class RegionalSettings
    def self.decimal_separator
      ENV["INGETRAZO_DECIMAL_SEPARATOR"].to_s.empty? ? "." : ENV["INGETRAZO_DECIMAL_SEPARATOR"]
    end
  end
  class DefinitionObserver; end
  class DefinitionsObserver; end
  class MaterialsObserver; end
  class ViewObserver; end
  class LayersObserver; end
  class InstanceObserver; end
  class FrameChangeObserver; end
  class PagesObserver; end
  class Importer
    ImportSuccess = 0
    ImportFail = 1
    ImportCanceled = 2
    ImportFileNotFound = 3
  end
  class Http; end
  class ImageRep; def initialize(*_a); end; end
  class Dimension < Drawingelement; end
  class Image < Drawingelement; end
end

class SketchupExtension
  attr_accessor :name, :description, :version, :creator, :copyright
  def initialize(name, loader); @name = name; @loader = loader; end
  def load_now; Kernel.require(@loader); end
  def check; true; end
  def loaded?; true; end
end

module LanguageHandler; end

def file_loaded?(_f); false; end
def file_loaded(_f); true; end
