require 'minitest/autorun'
require 'tmpdir'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  class << self
    attr_accessor :qa_messages
    def notify(op,data={});(@qa_messages ||= []) << [op,data];end
  end
end
class DownloadedPluginContracts < Minitest::Test
  def setup
    Host.reset_document;Bridge.qa_messages=[];@model=Sketchup.active_model
  end
  def face_record
    {'kind'=>'face','token'=>'original-face','outer'=>[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],'normal'=>[0,0,1]}
  end
  def component(key='shared',offset=0)
    {'component'=>true,'definition_key'=>key,'name'=>'Panel','xform'=>nil,
     'faces'=>[[[[offset,0,0],[1+offset,0,0],[1+offset,1,0],[offset,1,0]],[],{}]],'children'=>[]}
  end
  def test_selection_filters_native_entities_without_geometry_or_import_echo
    Host.set_selection([face_record,{'kind'=>'edge','token'=>'original-edge','a'=>[2,0,0],'b'=>[3,0,0]}],nil)
    Host.sync
    assert_empty Bridge.qa_messages.select { |op,_| %w[selection_changed upsert geometry_batch_begin].include?(op) }
    face=@model.selection.grep(Sketchup::Face).first
    @model.selection.remove(@model.selection.grep(Sketchup::Edge));Host.sync
    assert_equal [['selection_changed',{'items'=>[{'kind'=>'face','token'=>'original-face'}]}]],Bridge.qa_messages
    assert_same face,@model.selection.first
    assert_equal 0,@model.committed_revision
    Bridge.qa_messages=[];Host.sync;assert_empty Bridge.qa_messages
    @model.selection.clear;Host.sync
    assert_equal ['selection_changed',{'items'=>[]}],Bridge.qa_messages.last
  end
  def test_shared_definition_identity_does_not_merge_different_geometry
    owner=Sketchup::Entities.new(@model)
    a=Host.build_pick_entity(component,owner,0);b=Host.build_pick_entity(component,owner,0)
    different=Host.build_pick_entity(component('shared',2),owner,0)
    assert_same a.definition,b.definition
    refute_same a.definition,different.definition
    assert_equal 2,a.definition.instances.length
    assert_equal 1,a.definition.entities.faces.length
    assert_equal 0,@model.entities.length
  end
  def test_unselected_root_is_retired_by_immediate_native_undo
    group=@model.entities.add_group;group.entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    Host.sync;Host.dispatch('op'=>'native_binding','rid'=>group.entityID,'uid'=>'native-group')
    Bridge.qa_messages=[];Host.native_model_state('items'=>[],'event'=>'undo');Host.sync
    refute group.valid?
    refute Bridge.qa_messages.any? { |op,_| op=='upsert' }
  end
  def test_original_face_boundaries_cannot_become_new_loose_geometry
    Host.set_selection([face_record],nil)
    face=@model.selection.first
    @model.entities.erase_face_only(face)
    Host.set_selection([],nil)
    assert_empty Host.adapter_loose_items
  end
  def test_length_formatting_preserves_internal_units_in_math_and_json
    options=@model.options['UnitsOptions'];options['LengthUnit']=2;options['LengthPrecision']=2
    length=600.mm.to_l
    assert_instance_of Length,length
    assert_equal '600.00 mm',length.to_s
    assert_in_delta 600,JSON.parse(JSON.generate([length]))[0]*25.4,1e-8
    assert_in_delta 1200,(length*2)*25.4,1e-8
    assert_in_delta 1200,(2*length)*25.4,1e-8
    assert length>1
    assert_equal '1000000.00 mm²',Sketchup.format_area(1.m**2)
    assert_equal '600.000 mm',Sketchup.format_length(length,3)
    assert_equal Sketchup.version.to_i*100_000_000,Sketchup.version_number
    assert_equal Length::Feet,Length::SquareFeet
    assert_equal Length::Yard,Length::CubicYard
  end
  def test_empty_attribute_collection_has_no_fabricated_dictionary
    assert_empty @model.attribute_dictionaries.to_a
    assert_nil @model.attribute_dictionary('missing')
    assert_nil @model.attribute_dictionaries['missing']
  end
  def test_support_lookup_accepts_both_forms_of_logical_plugins_root
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root,'Example'))
      old=SketchupAdapter.roots;SketchupAdapter.roots=[root]
      assert_equal File.join(root,'Example'),Sketchup.find_support_file('Plugins/Example')
      assert_equal File.join(root,'Example'),Sketchup.find_support_file('Example','Plugins')
      assert_nil Sketchup.find_support_file('Plugins/missing')
    ensure
      SketchupAdapter.roots=old
    end
  end
  def test_empty_native_pages_support_observer_lifecycle
    observer=Object.new;assert @model.pages.add_observer(observer)
    assert_empty @model.pages.to_a;assert_nil @model.pages.selected_page
    assert @model.pages.remove_observer(observer)
    refute @model.pages.remove_observer(observer)
  end
end
