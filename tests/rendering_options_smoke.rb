require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'

module Bridge
  def self.notify(*); end
end

class RenderingOptionsSmoke < Minitest::Test
  class Watcher < Sketchup::RenderingOptionsObserver
    attr_reader :events
    def initialize; @events=[]; end
    def onRenderingOptionsChanged(options,type); @events << [options,type]; end
  end
  def setup
    Sketchup.reset_model!
    @options=Sketchup.active_model.rendering_options
    @observer=Watcher.new
    @options.add_observer(@observer)
  end
  def test_native_snapshot_is_one_coarse_event_and_unchanged_snapshots_are_silent
    values={'BackgroundColor'=>[10,20,30], 'FaceFrontColor'=>[200,201,202]}
    Host.dispatch('op'=>'rendering_options','values'=>values)
    assert_equal [10,20,30],@options['BackgroundColor'].to_a.first(3)
    assert_equal [200,201,202],@options['FaceFrontColor'].to_a.first(3)
    assert_equal [[@options,Sketchup::RenderingOptions::ROPAssign]],@observer.events
    Host.dispatch('op'=>'rendering_options','values'=>values)
    assert_equal 1,@observer.events.length
    @options.remove_observer(@observer)
    Host.dispatch('op'=>'rendering_options','values'=>{'BackgroundColor'=>[11,20,30]})
    assert_equal 1,@observer.events.length
    assert_equal [11,20,30],@options['BackgroundColor'].to_a.first(3)
  end
  def test_unsupported_or_invalid_keys_do_not_emit_or_mutate
    before=@options['FaceFrontColor'].to_a
    Host.dispatch('op'=>'rendering_options','values'=>{'InventedColor'=>[1,2,3], 'FaceFrontColor'=>[256,0,0]})
    assert_equal before,@options['FaceFrontColor'].to_a
    assert_nil @options['InventedColor']
    assert_empty @observer.events
  end
end
