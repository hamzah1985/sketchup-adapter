# SPDX-License-Identifier: GPL-3.0-or-later
# Additive APIs with executable semantics; no catch-all method_missing stubs.
TextAlignLeft = 0 unless defined?(TextAlignLeft)
TextAlignCenter = 1 unless defined?(TextAlignCenter)
TextAlignRight = 2 unless defined?(TextAlignRight)

module Sketchup
  Menu = UI::Menu unless const_defined?(:Menu, false)
  class InstancePath
    include Enumerable
    def initialize(path)
      raise TypeError, 'Expected Array' unless path.is_a?(Array)
      raise TypeError, 'Expected Sketchup::Entity values' unless path.all? { |item| item.is_a?(Entity) }
      @path = path.dup
    end
    def valid?
      !@path.empty? && @path.all?(&:valid?) && @path[0...-1].all? { |item| item.is_a?(Group) || item.is_a?(ComponentInstance) }
    end
    def check_entities!; raise TypeError, 'Instance path refers to deleted entities' unless @path.all?(&:valid?); end
    def each(&block); check_entities!; return enum_for(:each) unless block; @path.each(&block); nil; end
    def [](index); check_entities!; @path[index]; end
    def to_a; check_entities!; @path.dup; end
    def size; @path.size; end
    alias length size
    def empty?; @path.empty?; end
    def root; check_entities!; @path.first; end
    def leaf; check_entities!; @path.last; end
    def leaf=(entity); raise TypeError unless entity.is_a?(Entity); @path.empty? ? @path.push(entity) : @path[-1]=entity; end
    def push(entity); raise TypeError unless entity.is_a?(Entity); @path.push(entity); self; end
    def pop(*args); @path.pop(*args); end
    def clear; @path.clear; self; end
    def include?(entity); @path.include?(entity); end
    def clone; self.class.new(@path); end
    def copy(other); @path=other.to_a; self; end
    def ==(other); other.is_a?(InstancePath) && @path == other.to_a; end
    def persistent_id_path; check_entities!; @path.map(&:persistent_id).join('.'); end
    def transformation(index = nil)
      check_entities!
      unless index.nil?
        raise TypeError, 'Expected Integer index' unless index.is_a?(Integer)
        raise IndexError, 'Index outside instance path' if index < 0 || index >= size
      end
      items = index.nil? ? @path : @path.take(index+1)
      items.reduce(Geom::Transformation.new) { |transform, entity|
        entity.respond_to?(:transformation) ? transform * entity.transformation : transform
      }
    end
  end

  class EntitiesBuilder
    def initialize(entities); @entities=entities; @valid=true; end
    def valid?; @valid; end
    def invalidate!; @valid=false; end
    def entities; check!; @entities; end
    def check!; raise RuntimeError, 'EntitiesBuilder is no longer valid' unless valid?; end
    def vertex_at(point); check!; @entities.find_vertex(Geom::Point3d.new(point.to_a)); end
    def add_edge(*points)
      check!
      points=points.first if points.size==1 && points.first.is_a?(Array)
      raise ArgumentError, 'Expected two points' unless points.size==2
      a,b=points.map { |point| @entities.vertex(Geom::Point3d.new(point.to_a)) }
      return nil if a.equal?(b)
      @entities.edge(a,b)
    end
    alias add_line add_edge
    def add_edges(*points)
      check!
      points=points.first if points.size==1 && points.first.is_a?(Array)
      points.each_cons(2).map { |a,b| add_edge(a,b) }
    end
    def add_face(*points, holes: [])
      check!
      points=points.first if points.size==1 && points.first.is_a?(Array)
      loops = [points, *holes].map { |ring| ring.map { |point| Geom::Point3d.new(point.to_a) } }
      raise ArgumentError, 'A loop needs at least three points' if loops.any? { |ring| ring.length<3 }
      normal = Geom.newell(loops.first)
      raise ArgumentError, 'Degenerate face' unless normal.valid?
      plane=[loops.first.first, normal]
      raise ArgumentError, 'Points are not planar' unless loops.flatten(1).all? { |point| point.on_plane?(plane) }
      face=@entities.add_face_raw(loops.first)
      raise ArgumentError, 'Cannot create face' unless face
      loops.drop(1).each { |ring| face.add_hole(ring.map { |point| @entities.vertex(point) }) }
      face
    end
  end

  class Entities
    def build
      raise ArgumentError, 'Block required' unless block_given?
      raise RuntimeError, 'Entities.build cannot be nested' if @adapter_building
      @adapter_building=true
      builder=EntitiesBuilder.new(self)
      yield builder
      nil
    ensure
      builder.invalidate! if builder
      @adapter_building=false if builder
    end
    def clear!; erase_entities(to_a); nil; end
    def include?(entity); to_a.include?(entity); end
  end

  class Model
    def active_entities
      return @entities unless @active_path && !@active_path.empty?
      @active_path.last.definition.entities
    end
    def edit_transform
      return Geom::Transformation.new unless @active_path
      InstancePath.new(@active_path).transformation
    end
    def active_path=(path)
      if path && (!path.is_a?(Array) || path.any? { |item| !item.valid? || !(item.is_a?(Group) || item.is_a?(ComponentInstance)) })
        raise ArgumentError, 'Active path must contain valid groups or component instances'
      end
      # The worker models the context, but native context switching is not
      # claimed. Surface an explicit limitation rather than misplacing edits.
      unless path.nil? || path.empty?
        SketchupAdapter.gap('Model#active_path=', 'Worker edit context is supported; native edit context handoff is not yet implemented.')
      end
      @active_path=path && path.dup
    end
    def find_entity_by_persistent_id(*ids)
      result=ids.map { |id| find_entity_by_id(id) }.map { |entity| entity if entity && entity.valid? }
      ids.length==1 ? result.first : result
    end
    def instance_path_from_pid_path(path)
      ids=path.to_s.split('.').map { |id| Integer(id,10) }
      entities=ids.map { |id| find_entity_by_persistent_id(id) }
      return nil if entities.any?(&:nil?)
      result=InstancePath.new(entities)
      result.valid? ? result : nil
    rescue ArgumentError
      nil
    end
    def number_faces; entities.grep(Face).count(&:valid?); end
    def active_layer=(layer)
      # Older extensions also pass an existing layer's name. Resolve it to
      # the model-owned Layer; never silently create one for an invalid name.
      layer=@layers[layer] if layer.is_a?(String)
      raise ArgumentError, 'Expected valid Layer' unless layer.is_a?(Layer) && layer.valid?
      @adapter_active_layer=layer
      Bridge.notify('active_layer','name'=>layer.name) unless Sketchup.respond_to?(:bridge_events_silent?) && Sketchup.bridge_events_silent?
    end
    def active_layer; @adapter_active_layer || @layers[0]; end
  end

  class Set
    include Enumerable
    def initialize(items=[]); @items=items.uniq; end
    def each(&block); return enum_for(:each) unless block; @items.each(&block); end
    def insert(item); @items << item unless include?(item); self; end
    alias add insert
    def erase(item); @items.delete(item); self; end
    alias delete erase
    def include?(item); @items.include?(item); end
    alias contains? include?
    def clear; @items.clear; self; end
    def size; @items.size; end
    alias length size
    def empty?; @items.empty?; end
    def to_a; @items.dup; end
  end
end

module Sketchup
  def self.format_angle(number)
    raise TypeError,'Expected Numeric angle in radians' unless number.is_a?(Numeric)
    format_degrees(number.radians)
  end
  def self.format_degrees(number)
    raise TypeError,'Expected Numeric angle in degrees' unless number.is_a?(Numeric)
    precision=active_model.options['UnitsOptions']['AnglePrecision']
    precision=1 if precision.nil?
    format("%0.#{[[precision.to_i,0].max,12].min}f",number)
  end
end

# LanguageHandler used to be an empty module in the Bogdan-only shim.
Object.send(:remove_const, :LanguageHandler) if defined?(LanguageHandler) && !LanguageHandler.is_a?(Class)
class LanguageHandler
  def initialize(filename)
    source=caller_locations(1,1).first.absolute_path
    @base=source ? File.dirname(source) : Dir.pwd
    @resources=File.join(@base, 'Resources')
    @strings={}
    language=[Sketchup.get_locale, 'en-US'].uniq
    language.reverse_each do |locale|
      path=File.join(@resources,locale,filename)
      next unless File.file?(path)
      File.read(path,encoding:'UTF-8').scan(/"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;/).each do |key,value|
        decode=lambda { |text| text.gsub(/\\(["\\nrt])/) { {'n'=>"\n",'r'=>"\r",'t'=>"\t"}.fetch($1,$1) } }
        @strings[decode.call(key)]=decode.call(value)
      end
    end
  end
  def [](key); @strings.fetch(key,key); end
  def GetString(key); self[key]; end
  def strings; @strings.dup; end
  def resource_path(filename)
    [File.join(@resources,Sketchup.get_locale,filename),File.join(@resources,'en-US',filename),File.join(@base,filename)].find { |path| File.file?(path) }
  end
end

module UI
  class Command
    alias adapter_original_run run
    def run
      raise RuntimeError, 'This command belongs to a plugin that failed to initialize; restart after fixing it.' if @adapter_failed
      adapter_original_run
    end
    alias adapter_validation_state validation_state
    def validation_state; @adapter_failed ? MF_DISABLED : adapter_validation_state; end
  end
  class HtmlDialog
    def get_position; (@adapter_position || [0,0]).dup; end
    def set_position(x,y)
      @adapter_position=[x.to_i,y.to_i]
      Bridge.notify('dialog_pos','id'=>@id,'x'=>x.to_i,'y'=>y.to_i)
      true
    end
    def remember_position(x,y); @adapter_position=[x.to_i,y.to_i]; end
    def set_min_size(w,h); Bridge.notify('dialog_constraints','id'=>@id,'min_width'=>w.to_i,'min_height'=>h.to_i); nil; end
    def set_max_size(w,h); Bridge.notify('dialog_constraints','id'=>@id,'max_width'=>w.to_i,'max_height'=>h.to_i); nil; end
    def get_content_size; get_size; end
    def set_content_size(w,h); set_size(w,h); end
    def center; Bridge.notify('dialog_center','id'=>@id); nil; end
    def set_can_close(&block); @adapter_can_close=block; true; end
    alias set_can_close_callback set_can_close
    def adapter_can_close?; !@adapter_can_close || @adapter_can_close.call != false; end
    def close
      return false unless adapter_can_close?
      @visible=false
      Bridge.notify('dialog_close','id'=>@id)
      @on_closed.call if @on_closed
      true
    end
  end
  class WebDialog
    def initialize(title='',scrollable=true,key=nil,width=400,height=400,left=nil,top=nil,resizable=true)
      super(dialog_title:title,preferences_key:key,width:width,height:height,
            resizable:resizable,style:STYLE_UTILITY)
      set_position(left,top) if left && top
    end
    def show(&block)
      super()
      block.call(self) if block
      nil
    end
    def set_on_close(&block); set_on_closed(&block); end
    def show_modal(&block); show(&block); end
    def remember_values(values); @adapter_dom_values=values; end
    def get_element_value(id)
      return @adapter_dom_values[id.to_s] if @adapter_dom_values
      SketchupAdapter.gap('UI::WebDialog#get_element_value', 'DOM values are available during JavaScript callbacks; reads outside callbacks are not yet implemented.')
      raise SketchupAdapter::UnsupportedFeature, 'WebDialog DOM values are unavailable outside a callback'
    end
  end
end
