# IngeTrazo-specific services shared by all vendored extensions.
require_relative 'light_preview'
require_relative 'indexed_import'
require_relative 'fence_inference'
module Sketchup
  class << self
    def format_length(value, requested_precision=nil)
      units = active_model.options['UnitsOptions']
      unit = units['LengthUnit'].to_i
      factor, suffix = {0=>[1.0,'in'],1=>[1.0/12,'ft'],2=>[25.4,'mm'],
                        3=>[2.54,'cm'],4=>[0.0254,'m'],5=>[1.0/36,'yd']}.fetch(unit,[25.4,'mm'])
      precision = [[(requested_precision || units['LengthPrecision']).to_i,0].max,6].min
      format("%.#{precision}f %s", value.to_f * factor, suffix)
    end
    def parse_length(value)
      text = value.to_s.strip
      if text.match?(/\A[+-]?[\d.]+\z/)
        unit = active_model.options['UnitsOptions']['LengthUnit'].to_i
        text += ' ' + {0=>'in',1=>'ft',2=>'mm',3=>'cm',4=>'m',5=>'yd'}.fetch(unit,'mm')
      end
      text.to_l
    rescue ArgumentError
      nil
    end
    def format_area(value)
      units=active_model.options['UnitsOptions']
      unit=units['AreaUnit'] || units['LengthUnit']
      factor,suffix={0=>[1.0,'in'],1=>[1.0/12,'ft'],2=>[25.4,'mm'],
        3=>[2.54,'cm'],4=>[0.0254,'m'],5=>[1.0/36,'yd']}.fetch(unit.to_i,[25.4,'mm'])
      precision=[[((units['AreaPrecision'] || units['LengthPrecision']).to_i),0].max,6].min
      format("%.#{precision}f %s²",value.to_f*factor**2,suffix)
    end
  end
  class SectionPlane < Drawingelement
    attr_accessor :name, :symbol
    def initialize(point, normal)
      super()
      @name = ''; @symbol = ''
      set_plane([point, normal])
    end
    def set_plane(plane)
      @point, @normal = Geom.plane_parts(plane)
      true
    end
    def get_plane
      [@normal.x, @normal.y, @normal.z, -@normal.dot(Geom::Vector3d.new(@point.to_a))]
    end
    def activate; @parent_entities.active_section_plane = self; true; end
    def active?; @parent_entities.active_section_plane.equal?(self); end
    def bridge_data
      {'point'=>Host.m(@point), 'normal'=>@normal.to_a, 'active'=>active?,
       'name'=>@name, 'attrs'=>attribute_dictionaries ? attribute_dictionaries.to_h : {}}
    end
  end
  class Entities
    attr_accessor :active_section_plane
    def add_section_plane(point, normal = nil)
      point, normal = Geom.plane_parts(point) unless normal
      plane = SectionPlane.new(point, normal)
      plane.parent_entities = self
      @items << plane
      plane
    end
  end
  module Container
    def definition=(definition)
      raise ArgumentError, 'Expected a component definition' unless definition.is_a?(ComponentDefinition)
      @definition.instances_list.delete(self)
      @definition = definition
      @definition.instances_list << self
      definition
    end
  end
  class DefinitionList
    def load(path, *_args)
      path = File.expand_path(path.to_s)
      raise IOError, "Component file not found: #{path}" unless File.file?(path)
      data = Bridge.call('load_component', 'path'=>path)
      raise IOError, (data || {})['error'] || 'IngeTrazo did not return the component' unless data && data['geometry']
      private_entities = Entities.new(Sketchup.active_model)
      inst = Host.build_pick_entity(data['geometry'], private_entities, 0)
      raise IOError, 'No imported component geometry' unless inst
      definition = inst.definition
      inst.erase!
      definition
    end
  end
  class Model
    def export(path, options = {})
      response = Bridge.call('export_model', 'path'=>File.expand_path(path.to_s), 'options'=>options)
      raise IOError, (response || {})['error'] || 'Native export failed' unless response && response['ok']
      true
    end
  end
end

module Host
  class << self
    def face_material_stamp(face)
      cache = {}
      Digest::SHA1.hexdigest(JSON.generate([material_attrs(face.material,cache),
        material_attrs(face.back_material,cache),
        face.uv_mapping && face.uv_mapping.map(&:to_a),
        face.uv_mapping_back && face.uv_mapping_back.map(&:to_a)]))
    end
    def face_side_stamp(face, front)
      material = front ? face.material : face.back_material
      mapping = front ? face.uv_mapping : face.uv_mapping_back
      Digest::SHA1.hexdigest(JSON.generate([material_attrs(material, {}), mapping && mapping.map(&:to_a)]))
    end
    def restore_material(data)
      return nil unless data.is_a?(Hash) && (data['mat'] || data['color'] || data['texture'])
      name = data['mat'].to_s
      name = 'IngeTrazo finish ' + Digest::SHA1.hexdigest(JSON.generate(data))[0,12] if name.empty?
      material = Sketchup.active_model.materials[name] || Sketchup.active_model.materials.add(name)
      if data['color']
        color = data['color'].first(3).map(&:to_f)
        color = color.map { |v| v * 255 } if color.all? { |v| v <= 1 }
        material.color = color.map(&:round)
      end
      material.alpha = data['opacity'].to_f if data['opacity']
      tex = data['texture']
      if tex.is_a?(Hash) && tex['path'] && File.file?(tex['path'])
        material.texture = [tex['path'], (tex['sw'] || 1).to_f / INCH, (tex['sh'] || 1).to_f / INCH]
      end
      material
    end

    # Surface proxies are rebuilt during selection polling. Do not mutate a
    # plugin's model materials when a native face happens to use the same name.
    # Cache equivalent finishes for material-identity comparisons in plugins.
    def restore_surface_material(data)
      return nil unless data.is_a?(Hash) && (data['mat'] || data['color'] || data['texture'])
      texture = data['texture'].is_a?(Hash) ? data['texture'].reject { |key,_| key == 'uvw' } : data['texture']
      key = JSON.generate([data['mat'], data['color'], data['opacity'], texture])
      @native_surface_materials ||= {}
      return @native_surface_materials[key] if @native_surface_materials[key]
      name = data['mat'].to_s
      name = 'IngeTrazo finish ' + Digest::SHA1.hexdigest(key)[0,12] if name.empty?
      material = Sketchup::Material.new(name)
      if data['color']
        color = data['color'].first(3).map(&:to_f)
        color = color.map { |v| v * 255 } if color.all? { |v| v <= 1 }
        material.color = color.map(&:round)
      end
      material.alpha = data['opacity'].to_f if data['opacity']
      if texture.is_a?(Hash) && texture['path'] && File.file?(texture['path'])
        material.texture = [texture['path'], (texture['sw'] || 1).to_f / INCH, (texture['sh'] || 1).to_f / INCH]
      end
      @native_surface_materials[key] = material
    end

    def restore_face_materials(face, attrs, resolver = nil)
      resolver ||= method(:restore_material)
      face.material = resolver.call(attrs)
      face.back_material = resolver.call(attrs['back']) if attrs['back'].is_a?(Hash)
      [[attrs, true], [attrs['back'], false]].each do |data, front|
        uvw = data.is_a?(Hash) && data['texture'].is_a?(Hash) && data['texture']['uvw']
        next unless uvw && uvw.length == 8
        mapping = face.outer_loop.points.first(3).flat_map do |p|
          xyz = m(p)
          uv = [uvw[0]*xyz[0]+uvw[1]*xyz[1]+uvw[2]*xyz[2]+uvw[3],
                uvw[4]*xyz[0]+uvw[5]*xyz[1]+uvw[6]*xyz[2]+uvw[7]]
          [p, Geom::Point3d.new(uv[0],uv[1],1)]
        end
        front ? face.uv_mapping = mapping : face.uv_mapping_back = mapping
      end
      face.set_attribute('_ingetrazo_bridge','restored_material_stamp',face_material_stamp(face))
      face.instance_variable_set(:@adapter_paint_baseline_front, face_side_stamp(face, true))
      face.instance_variable_set(:@adapter_paint_baseline_back, face_side_stamp(face, false))
      face.instance_variable_set(:@adapter_paint_mapping_front, face.uv_mapping && face.uv_mapping.map(&:to_a))
      face.instance_variable_set(:@adapter_paint_mapping_back, face.uv_mapping_back && face.uv_mapping_back.map(&:to_a))
      face.instance_variable_set(:@adapter_original_material_front, face.material)
      face.instance_variable_set(:@adapter_original_material_back, face.back_material)
      face.instance_variable_set(:@adapter_paint_dirty_front, false)
      face.instance_variable_set(:@adapter_paint_dirty_back, false)
    end

    def with_native_scene
      data = Bridge.call('scene_snapshot')
      return yield Sketchup.active_model unless data.is_a?(Hash)
      original = Sketchup.active_model
      copy = Sketchup::Model.new
      Sketchup.instance_variable_set(:@model, copy)
      Array(data['groups']).each { |g| build_pick_entity(g, copy.entities, 0) }
      if data['loose']
        loose = build_pick_entity(data['loose'], Sketchup::Entities.new(copy), 0)
        Sketchup.active_model.definitions.copy_entities(loose.entities, copy.entities) if loose
      end
      copy.title = data['title'].to_s unless data['title'].to_s.empty?
      yield copy
    ensure
      Sketchup.instance_variable_set(:@model, original) if original
    end
  end
end

def install_ingetrazo_overrides
  if defined?(BogdanWallCrafter::DrawingTool) && !BogdanWallCrafter::DrawingTool.ancestors.include?(Host::FenceInference)
    BogdanWallCrafter::DrawingTool.prepend(Host::FenceInference)
  end
  if defined?(Essentials::CompactFaucet) && !Essentials::CompactFaucet.singleton_class.ancestors.include?(Host::CompactFaucetImport)
    Essentials::CompactFaucet.singleton_class.prepend(Host::CompactFaucetImport)
  end
  if defined?(BogdanLightCrafter::SurfaceTool) && !BogdanLightCrafter::SurfaceTool.ancestors.include?(Host::SurfacePreview)
    BogdanLightCrafter::SurfaceTool.prepend(Host::SurfacePreview)
  end
  if defined?(BogdanLightCrafter::PendantTool) && !BogdanLightCrafter::PendantTool.ancestors.include?(Host::HangingPreview)
    BogdanLightCrafter::PendantTool.prepend(Host::HangingPreview)
  end
  if defined?(BogdanModelViewer2::Walkthrough)
    # Use IngeTrazo's actual ray picking, camera and textured preview lifecycle.
    # The Ruby View compatibility object cannot render a native avatar/camera.
    BogdanModelViewer2::Walkthrough.define_singleton_method(:run) do
      response = Bridge.call('native_walkthrough')
      raise IOError, (response || {})['error'] || 'Walkthrough could not start' unless response.is_a?(Hash) && response['ok']
      response['active']
    end
  end
  if defined?(BogdanHide)
    actions = {'state'=>%w[scope], 'set_category_hidden'=>%w[key hidden scope],
               'set_view_hidden'=>%w[key hidden], 'hide_selected'=>[],
               'isolate_selected'=>[], 'show_hidden_selection'=>%w[scope], 'show_everything'=>[]}
    actions.each do |name,keys|
      original = BogdanHide.method(name)
      BogdanHide.define_singleton_method(name) do |*args|
        params = {'action'=>name}
        keys.zip(args).each { |key,value| params[key]=value }
        response = Bridge.call('native_hide',params)
        # Isolated Ruby tests have no native document service.
        next original.call(*args) unless response.is_a?(Hash)
        raise response['error'] if response['error']
        response[name == 'state' ? 'state' : 'message']
      end
    end
  end
  if defined?(BogdanLightCrafter::Dialog)
    # Qt WebEngine accepts these payloads atomically; CEF's chunk protocol can
    # time out while many panels are opening and leave a partial catalogue.
    BogdanLightCrafter::Dialog.define_singleton_method(:send_payload) do |method, payload|
      allowed = %w[setCatalog setThumbs setCurrent setEditState editError]
      raise ArgumentError, 'Unknown Light Crafter message' unless allowed.include?(method)
      script("LC.#{method}(#{JSON.generate(payload)})")
    end
  end
  return unless defined?(BogdanModelViewer2::Exporter)
  # The native GLB writer keeps hierarchy, UVs and material sides. Snapshot
  # metadata is read from a temporary complete scene, never selection copies.
  BogdanModelViewer2::SketchupGlbExporter.singleton_class.class_eval do
    define_method(:export) do |model, path|
      model.export(path, show_summary:false)
      path
    end
  end
  mod = BogdanModelViewer2::Exporter.singleton_class
  mod.alias_method(:bridge_original_snapshot, :build_snapshot)
  mod.define_method(:build_snapshot) do |_model, path, inputs = {}|
    Host.with_native_scene { |model| bridge_original_snapshot(model, path, inputs) }
  end
end
