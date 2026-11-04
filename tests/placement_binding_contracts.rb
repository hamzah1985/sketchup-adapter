require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'

module Bridge
  class << self
    attr_accessor :events
    def notify(op, data = {}); (@events ||= []) << { 'op' => op }.merge(data); end
    def call(*); nil; end
  end
end

# Tests the Ruby protocol and object lifecycle without a native IngeTrazo
# process. Native click, preview, and history tests are separate fixtures.
class PlacementBindingContracts < Minitest::Test
  IDENTITY = [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1].freeze

  def setup
    Host.reset_document
    Bridge.events = []
    @model = Sketchup.active_model
  end

  def definition(name)
    item = @model.definitions.add(name)
    item.entities.add_face([0,0,0], [40,0,0], [0,40,0])
    item
  end

  def place(name, uid)
    item = definition(name)
    Host.pending_place(item)
    assert_equal 1, Host.instance_variable_get(:@pending).size
    Bridge.events.clear
    Host.dispatch('op' => 'placed', 'def' => item.entityID, 'uid' => uid, 'xform' => IDENTITY)
    bind = Bridge.events.find { |e| e['op'] == 'bind' && e['uid'] == uid }
    refute_nil bind, 'Ruby must acknowledge the exact native object binding'
    assert_empty Host.instance_variable_get(:@pending)
    instance = @model.entities.to_a.find { |e| e.entityID == bind['rid'] }
    refute_nil instance
    [instance, bind['rid']]
  end

  def model_state(items, event, live)
    Host.native_model_state('items' => items, 'event' => event, 'live_uids' => live)
  end

  def test_placed_component_tracks_native_undo_redo_and_transform
    a, a_id = place('first', 'uid-a')
    b, b_id = place('second', 'uid-b')
    assert_equal a_id, Host.instance_variable_get(:@uid_to_rid)['uid-a']
    assert_equal b_id, Host.instance_variable_get(:@uid_to_rid)['uid-b']
    other = {'uid'=>'uid-b', 'rid'=>b_id, 'xform'=>IDENTITY}
    model_state([other], 'undo', ['uid-b'])
    refute a.valid?, 'native undo must retire the corresponding Ruby component'
    assert b.valid?, 'undo must not retire another still-live component'
    refute_includes @model.entities.to_a, a
    assert_includes @model.entities.to_a, b
    moved = IDENTITY.dup; moved[12] = 2.5
    restored = {'uid'=>'uid-a', 'rid'=>a_id, 'xform'=>moved}
    model_state([restored, other], 'redo', %w[uid-a uid-b])
    assert a.valid?, 'native redo must restore the original Ruby instance'
    assert_same a, @model.entities.to_a.find { |e| e.entityID == a_id }
    assert_in_delta 2.5 / Host::INCH, a.transformation.origin.x, 1e-7
    assert b.valid?
    model_state([other], 'undo', ['uid-b'])
    refute a.valid?
    model_state([restored, other], 'redo', %w[uid-a uid-b])
    assert_same a, @model.entities.to_a.find { |e| e.entityID == a_id }
  end

  def test_cancel_clears_only_pending_definition_and_creates_no_instance
    existing, = place('existing', 'uid-existing')
    item = definition('cancelled')
    Host.pending_place(item)
    before = @model.entities.to_a.dup
    Bridge.events.clear
    Host.dispatch('op'=>'place_cancelled', 'def'=>item.entityID)
    assert_empty Host.instance_variable_get(:@pending)
    assert_equal before, @model.entities.to_a
    assert existing.valid?
    refute Bridge.events.any? { |e| e['op'] == 'bind' }, 'cancelled placement must not bind'
    refute Bridge.events.any? { |e| e['op'] == 'error' }
  end
end
