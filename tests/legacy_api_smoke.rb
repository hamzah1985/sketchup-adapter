require 'minitest/autorun'
require 'tmpdir'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  class << self
    attr_accessor :test_reply
    def notify(*); end
    def call(*); @test_reply; end
  end
end
class LegacyAPITest < Minitest::Test
  def setup; Sketchup.reset_model!; end
  class SpaceTool
    attr_reader :finished, :keys
    def initialize; @finished=false; @keys=[]; end
    def onKeyDown(key, _repeat, _flags, _view)
      @keys << key
      @finished=true if key == VK_SPACE
    end
  end
  def test_space_key_reaches_extension_tool_and_matches_sketchup_constant
    tool=SpaceTool.new
    Host.select_tool(tool)
    id=Host.active_tool_id
    Host.dispatch_tool_event('id'=>id, 'event'=>'key', 'key'=>37)
    refute tool.finished
    Host.dispatch_tool_event('id'=>id, 'event'=>'key', 'key'=>32)
    assert tool.finished
    assert_equal [37,32], tool.keys
  ensure
    Host.select_tool(nil)
  end
  def test_projection_accepts_array_and_legacy_point_vector_arguments
    point=Geom::Point3d.new(2,3,4)
    origin=Geom::Point3d.new(0,0,0)
    assert_equal [2.0,3.0,0.0],point.project_to_plane(origin,Z_AXIS).to_a
    assert_equal point.project_to_plane([origin,Z_AXIS]),point.project_to_plane(origin,Z_AXIS)
    assert_equal [2.0,0.0,0.0],point.project_to_line(origin,X_AXIS).to_a
  end
  def test_inputbox_preserves_numeric_types_strings_and_cancel
    Bridge.test_reply=['2','4.5','600 mm']
    values=UI.inputbox(['Count','Angle','Width'],[1,30.0,'300 mm'])
    assert_equal [2,4.5,'600 mm'],values
    assert_instance_of Integer,values[0]
    assert_instance_of Float,values[1]
    Bridge.test_reply=nil
    assert_equal false,UI.inputbox(['Count'],[1])
  end
  def test_existing_layer_names_resolve_and_unknown_names_fail
    model=Sketchup.active_model
    layer=model.layers.add('Roof')
    model.active_layer='Roof'
    assert_same layer,model.active_layer
    assert_raises(ArgumentError) { model.active_layer='Absent' }
    assert_same layer,model.active_layer
  end
  def test_angle_information_obeys_model_precision
    assert_equal '180.0',Sketchup.format_angle(Math::PI)
    Sketchup.active_model.options['UnitsOptions']['AnglePrecision']=3
    assert_equal '30.000',Sketchup.format_angle(30.degrees)
    assert_raises(TypeError) { Sketchup.format_angle('30') }
  end
  def test_view_drawing_accepts_point_lists_varargs_and_single_points
    view=Sketchup.active_model.active_view
    a=Geom::Point3d.new(1,2,3);b=Geom::Point3d.new(4,5,6)
    view.begin_overlay_capture
    assert_same view,view.draw(GL_LINES,a,b)
    view.draw(GL_LINES,[a,b])
    view.draw_line(a,b)
    view.draw_polyline(a,b)
    view.draw2d(GL_LINES,[1,2],[3,4])
    view.draw_points(a,8,2,'blue')
    view.draw_points([7,8,9],4)
    view.draw(GL_LINE_STRIP,nil,nil)
    items=view.take_overlay
    assert_equal 7,items.length
    assert_equal [a.to_a,b.to_a],items[0]['points']
    assert_equal items[0]['points'],items[1]['points']
    assert_equal 'line_strip',items[3]['mode']
    assert_equal 'screen',items[4]['space']
    assert_equal [[1.0,2.0,3.0]],items[5]['points']
    assert_equal [0,0,255,255],items[5]['color']
    assert_equal [[7.0,8.0,9.0]],items[6]['points']
  end
  def test_filtering_api_arrays_does_not_mutate_model_topology
    entities=Sketchup.active_model.entities
    face=entities.add_face([[0,0,0],[10,0,0],[10,10,0],[0,10,0]])
    vertex=face.vertices.first;edge=face.edges.first;loop=face.outer_loop
    vertex.edges.clear
    edge.faces.clear
    loop.vertices.clear
    face.loops.clear
    assert_equal 2,vertex.edges.length
    assert_equal [face],edge.faces
    assert_equal 4,loop.vertices.length
    assert_equal 1,face.loops.length
    entities.add_line([0,0,0],[10,10,0])
    assert_equal 2,entities.faces.length
    assert_in_delta 100,entities.faces.sum(&:area),1e-7
  end
  def test_support_directory_lookup_returns_private_plugin_root
    previous_roots=SketchupAdapter.roots
    previous_current=SketchupAdapter.current_root
    Dir.mktmpdir('support-path-') do |root|
      SketchupAdapter.current_root=root;SketchupAdapter.roots=[root]
      assert_equal root.tr('\\','/'),Sketchup.find_support_file('Plugins').tr('\\','/')
      assert_nil Sketchup.find_support_file('absent.rb','Plugins')
      File.write(File.join(root,'resource.svg'),'fixture')
      assert_equal File.join(root,'resource.svg').tr('\\','/'),Sketchup.find_support_file('resource.svg','Plugins/').tr('\\','/')
    end
  ensure
    SketchupAdapter.roots=previous_roots;SketchupAdapter.current_root=previous_current
  end
  def test_fitted_plane_accepts_vertex_coordinates_without_mutating_vertices
    face=Sketchup.active_model.entities.add_face([[1,2,3],[5,2,3],[5,7,3],[1,7,3]])
    vertices=face.vertices
    plane=Geom.fit_plane_to_points(vertices)
    assert vertices.all? { |v| v.position.distance_to_plane(plane)<1e-7 }
    assert_equal 4,face.vertices.length
  end
  def test_legacy_line_preview_color_and_endpoint_array
    view=Sketchup.active_model.active_view
    view.drawing_color='blue';view.begin_overlay_capture
    view.draw_line(ORIGIN,[10,0,0],'orange')
    assert_equal 'blue',view.drawing_color
    assert_equal [255,165,0,255],view.take_overlay.first['color']
    view.draw_line([ORIGIN,[10,0,0]],'orange')
    assert_equal 2,view.take_overlay.first['points'].length
    view.draw_line(ORIGIN,[10,0,0],[0,1,0],[10,1,0])
    assert_equal 4,view.take_overlay.first['points'].length
    edge=Sketchup.active_model.entities.add_line([[0,0,0],[10,0,0]])
    assert_in_delta 10,edge.length,1e-7
  end
  def test_native_export_hides_groups_on_invisible_layers
    model=Sketchup.active_model
    group=model.entities.add_group
    group.entities.add_face([[0,0,0],[10,0,0],[10,8,0],[0,8,0]])
    group.layer=model.layers.add('Backup')
    group.layer.visible=false
    refute group.hidden?
    assert Host.export_container(group)['hidden']
    group.layer.visible=true
    refute Host.export_container(group)['hidden']
  end
  def test_new_operation_closes_previous_before_abort
    model=Sketchup.active_model
    model.start_operation('First')
    first=model.entities.add_line([0,0,0],[10,0,0])
    model.start_operation('Second')
    second=model.entities.add_line([0,1,0],[10,1,0])
    assert_equal 1,model.operation_depth
    model.abort_operation
    assert first.valid?
    refute second.valid?
    assert_equal [first],model.entities.edges
    assert_equal 0,model.operation_depth
  end
end
