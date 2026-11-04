require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'

module Bridge
  class << self
    attr_accessor :events
    def notify(op, data = {}); (@events ||= []) << { 'op' => op }.merge(data); end
    def call(*); nil; end
  end
end

class ExtensionAbortContracts < Minitest::Test
  def setup
    Sketchup.reset_model!
    Host.instance_variable_set(:@host_faces, {})
    Host.instance_variable_set(:@host_edges, [])
    Host.instance_variable_set(:@proxy_groups, [])
    Bridge.events = []
  end

  def test_extension_exit_aborts_operation_and_does_not_publish_partial_geometry
    model = Sketchup.active_model
    after_exit = false
    cmd = UI::Command.new('abort fixture') do
      model.start_operation('unfinished')
      model.entities.add_face([[0,0,0], [2,0,0], [0,2,0]])
      exit(7)
      after_exit = true
    end
    Host.dispatch('op' => 'command', 'id' => cmd.id)
    refute after_exit
    assert_equal 0, model.operation_depth
    assert_empty model.entities.faces
    assert_equal [{'op'=>'extension_abort', 'where'=>'command', 'status'=>7}],
      Bridge.events.select { |e| e['op'] == 'extension_abort' }
    assert_empty Bridge.events.select { |e| %w[upsert surface_patch face_erased].include?(e['op']) }
    Host.dispatch('op' => 'ping')
    assert Bridge.events.any? { |e| e['op'] == 'pong' }, 'worker must remain responsive'
  end

  def test_abort_without_operation_does_not_publish_unsynced_geometry
    model = Sketchup.active_model
    cmd = UI::Command.new('abort without operation') do
      model.entities.add_face([[0,0,0], [2,0,0], [0,2,0]])
      abort('fixture requested stop')
    end
    Host.dispatch('op' => 'command', 'id' => cmd.id)
    assert Bridge.events.any? { |e| e['op'] == 'extension_abort' }
    assert_empty Bridge.events.select { |e| %w[upsert surface_patch face_erased].include?(e['op']) }
  end

  def test_host_quit_still_exits
    error = assert_raises(SystemExit) { Host.dispatch('op' => 'quit') }
    assert_equal 0, error.status
    refute Bridge.events.any? { |e| e['op'] == 'extension_abort' }
  end

  def test_dialog_callback_abort_is_reported_without_running_following_code
    dialog = UI::HtmlDialog.new(dialog_title: 'abort fixture')
    finished = false
    dialog.add_action_callback('run') do |_context|
      exit(9)
      finished = true
    end
    Bridge.events.clear
    Host.dispatch('op'=>'callback', 'dialog'=>dialog.id, 'name'=>'run', 'args'=>[])
    refute finished
    assert_equal [{'op'=>'extension_abort', 'where'=>'callback', 'status'=>9}],
      Bridge.events.select { |e| e['op']=='extension_abort' }
    Host.dispatch('op'=>'ping')
    assert Bridge.events.any? { |e| e['op']=='pong' }
  end
end
