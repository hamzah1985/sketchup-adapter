require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  class << self
    attr_accessor :events
    def notify(op,data={}); (@events||=[]) << {'op'=>op}.merge(data); end
    def call(*); nil; end
  end
end
class FragmentLifecycleContracts < Minitest::Test
  def setup
    Sketchup.reset_model!
    Host.instance_variable_set(:@host_faces,{})
    Host.instance_variable_set(:@host_edges,[])
    Host.instance_variable_set(:@proxy_groups,[])
    Bridge.events=[]
    Host.set_selection([{'kind'=>'face','token'=>'source',
      'outer'=>[[0,0,0],[4,0,0],[4,4,0],[0,4,0]]}],nil)
    Bridge.events.clear
  end
  def test_surviving_fragment_remains_reportable_after_source_proxy_erased
    entities=Sketchup.active_model.entities
    source=Sketchup.active_model.selection.first
    fragment=entities.add_face_raw([[200,0,0],[210,0,0],[210,10,0],[200,10,0]])
    fragment.instance_variable_set(:@adapter_surface_token,'source')
    source.erase!
    Host.sync
    assert Bridge.events.any? { |e| e['op']=='surface_patch' && e['token']=='source' }
    refute Bridge.events.any? { |e| e['op']=='face_erased' && e['token']=='source' }
    Bridge.events.clear
    fragment.reverse!
    Host.sync
    assert Bridge.events.any? { |e| e['op']=='surface_patch' && e['token']=='source' },
      'a later fragment edit must be reported or safely rejected, not silently ignored'
  end
  def test_complete_deletion_still_emits_erasure
    Sketchup.active_model.selection.first.erase!
    Host.sync
    assert Bridge.events.any? { |e| e['op']=='face_erased' && e['token']=='source' }
  end
end
