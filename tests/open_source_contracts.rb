require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  class << self
    attr_accessor :test_context,:test_messages,:context_calls
    def notify(op,data={});(@test_messages ||= []) << [op,data];end
    def call(name,data={})
      return nil unless name=='scene_snapshot'
      @context_calls=@context_calls.to_i+1
      {'native_context'=>@test_context || []}
    end
  end
end
class OpenSourceContracts < Minitest::Test
  def setup
    Host.reset_document;Bridge.test_messages=[];Bridge.test_context=[];Bridge.context_calls=0
    @model=Sketchup.active_model
  end
  def context_face
    {'kind'=>'face','token'=>'unselected-native-face','outer'=>[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],'normal'=>[0,0,1]}
  end
  def test_original_stl_mesh_has_shared_vertex_indices_and_keeps_hole_area
    face=@model.entities.add_face([[0,0,0],[10,0,0],[10,8,0],[0,8,0]])
    mesh=face.mesh
    assert_equal 4,mesh.count_points
    assert_equal 2,(mesh.polygon_at(1)&mesh.polygon_at(2)).size
    index=mesh.add_point([0,0,0]);assert_equal index,mesh.add_point([0,0,0])
    assert_equal 4,mesh.count_points
  end
  def test_line_predicate_accepts_points_and_packed_line
    point=Geom::Point3d.new(2,2,0)
    assert point.on_line?([0,0,0],[1,1,0])
    assert point.on_line?([[0,0,0],[1,1,0]])
    refute point.on_line?([0,0,0],[1,0,0])
  end
  def test_group_definitions_instantiate_as_groups_without_component_semantics
    group=@model.entities.add_group
    copy=@model.entities.add_instance(group.definition,IDENTITY)
    assert_instance_of Sketchup::Group,copy
    assert_same group.definition,copy.definition
    assert_equal 2,group.definition.instances.size
    assert_equal 0,copy.definition.behavior.no_scale_mask?
  end
  def test_model_enumeration_reads_unselected_native_context_once_without_history
    Bridge.test_context=[context_face]
    measured=[]
    command=UI::Command.new('QA enumerate model') { measured << @model.entities.faces.length }
    Host.dispatch('op'=>'command','id'=>command.id)
    assert_equal [1],measured
    assert_equal 1,Bridge.context_calls
    assert_equal 0,@model.committed_revision
    refute Bridge.test_messages.any? { |op,_| %w[upsert removed surface_patch].include?(op) }
    assert_empty @model.selection.to_a
  end
  def test_failed_command_aborts_new_operation_and_keeps_imported_context
    Bridge.test_context=[context_face]
    command=UI::Command.new('QA failed generator') do
      @model.start_operation('partial')
      @model.entities.add_group.entities.add_face([[0,0,0],[2,0,0],[2,2,0],[0,2,0]])
      raise 'authored fault'
    end
    Host.dispatch('op'=>'command','id'=>command.id)
    assert_equal 0,@model.operation_depth
    assert_equal 1,@model.entities.faces.length
    assert_empty @model.entities.grep(Sketchup::Group)
    assert Bridge.test_messages.any? { |op,_| op=='error' }
    refute Bridge.test_messages.any? { |op,_| %w[upsert removed surface_patch].include?(op) }
  end
  def test_source_surface_edge_flags_survive_fragment_export
    item=context_face
    item['edge_properties']=[{'points'=>[[0,0,0],[1,0,0]],'soft'=>true,'smooth'=>true,'casts_shadows'=>false}]
    Host.set_selection([item],nil)
    face=@model.selection.first;data=Host.native_surface_faces([face]).first[2]['_sketchup_edge_properties']
    flagged=data.find { |record| record['soft'] }
    assert flagged['smooth'];refute flagged['casts_shadows']
    assert_equal 4,data.size
  end
  def test_importer_status_constants_menu_alias_and_rendering_colors
    assert_same UI::Menu,Sketchup::Menu
    assert_equal 0,Sketchup::Importer::ImportSuccess
    assert_equal 4,[Sketchup::Importer::ImportSuccess,Sketchup::Importer::ImportFail,Sketchup::Importer::ImportCanceled,Sketchup::Importer::ImportFileNotFound].uniq.size
    assert_equal [255,255,255,255],@model.rendering_options['FaceFrontColor'].to_a
  end
end
