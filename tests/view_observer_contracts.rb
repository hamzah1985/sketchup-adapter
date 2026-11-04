require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  class << self
    def notify(*); end
    def call(*); nil; end
  end
end
class ViewObserverContracts < Minitest::Test
  class Watcher < Sketchup::ViewObserver
    attr_reader :events
    def initialize; @events=[]; end
    def onViewChanged(view); @events << [view.camera.eye.to_a,view.vpwidth,view.vpheight]; end
  end
  def setup
    Sketchup.reset_model!
    @view=Sketchup.active_model.active_view
    @values={'eye'=>[3,4,5], 'target'=>[1,2,3], 'up'=>[0,0,1], 'perspective'=>true,
             'fov'=>60, 'height'=>4, 'viewport_size'=>[1000,500]}
  end
  def test_native_camera_notifies_once_and_uses_model_units
    watch=Watcher.new
    assert @view.add_observer(watch)
    refute @view.add_observer(watch)
    @view.apply_native_camera(@values)
    assert_equal 1,watch.events.size
    assert_in_delta 3.0/Host::INCH,@view.camera.eye.x,1e-7
    assert_in_delta 1.0/Host::INCH,@view.camera.target.x,1e-7
    assert_equal [1000,500],[@view.vpwidth,@view.vpheight]
    @view.apply_native_camera(@values.dup)
    assert_equal 1,watch.events.size
    @view.set_cursor_data({})
    assert_equal [1000,500],[@view.vpwidth,@view.vpheight]
    assert @view.remove_observer(watch)
    @view.apply_native_camera(@values.merge('fov'=>50))
    assert_equal 1,watch.events.size
  end
  def test_malformed_camera_does_not_notify_or_change_state
    watch=Watcher.new;@view.add_observer(watch)
    @view.apply_native_camera(@values.merge('fov'=>Float::NAN))
    assert_empty watch.events
    refute @view.native_camera?
  end
end
