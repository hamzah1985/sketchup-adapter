require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  class << self
    attr_accessor :events, :snapshot
    def notify(op,data={}); (@events||=[]) << {'op'=>op}.merge(data); end
    def call(fn,*); fn=='scene_snapshot' ? snapshot : nil; end
  end
end
class NativeGroupObservers < Minitest::Test
  class EntitiesWatch < Sketchup::EntitiesObserver
    attr_reader :added,:removed
    def initialize;@added=[];@removed=[];end
    def onElementAdded(_entities,entity);@added << entity.entityID;end
    def onElementRemoved(_entities,id);@removed << id;end
  end
  def setup
    Sketchup.reset_model!
    Host.reset_document
    Bridge.events=[];Bridge.snapshot=nil
    @model=Sketchup.active_model
  end
  def item(uid='a',x=1)
    {'kind'=>'group','uid'=>uid,'geometry'=>{'uid'=>uid,'name'=>'native',
      'component'=>false,'xform'=>nil,'faces'=>[[[[0,0,0],[x,0,0],[0,1,0]],[],{}]],
      'edges'=>[],'soft_edges'=>[],'children'=>[]}}
  end
  def test_selection_refresh_keeps_native_proxy_identity_and_is_read_only
    Host.set_selection([item],nil)
    group=@model.selection.first;id=group.entityID
    Host.set_selection([],nil)
    assert group.valid?
    Host.set_selection([item],nil)
    assert_same group,@model.selection.first
    Host.set_selection([item('a',2)],nil)
    assert_same group,@model.selection.first
    assert_equal id,@model.selection.first.entityID
    assert_in_delta 2.0/Host::INCH,group.bounds.width,0.00001
    Bridge.events.clear;Host.sync
    assert_empty Bridge.events.select { |e| %w[upsert removed surface_patch face_erased].include?(e['op']) }
  end
  def test_real_native_add_delete_and_undo_notify_once
    watch=EntitiesWatch.new;@model.entities.add_observer(watch)
    Host.native_model_state('items'=>[],'event'=>'commit','live_uids'=>['a'],'added_uids'=>['a'])
    assert_empty watch.added
    Host.set_selection([item],nil)
    group=@model.selection.first
    assert_equal [group.entityID],watch.added
    Host.set_selection([item],nil)
    assert_equal [group.entityID],watch.added
    Host.native_model_state('items'=>[],'event'=>'commit','live_uids'=>[],'removed_uids'=>['a'])
    refute group.valid?
    assert_equal [group.entityID],watch.removed
    Host.native_model_state('items'=>[{'uid'=>'a','rid'=>group.entityID}],'event'=>'undo','live_uids'=>['a'])
    assert group.valid?
  end
  def test_live_nested_proxy_is_not_deleted_when_not_in_top_level_items
    Host.set_selection([item],nil)
    group=@model.selection.first
    Host.native_model_state('items'=>[],'event'=>'commit','live_uids'=>['a'])
    assert group.valid?
    assert_includes @model.entities.to_a,group
  end
  def test_native_commit_reaches_model_observers
    observer=Class.new(Sketchup::ModelObserver) do
      attr_reader :commits
      def initialize;@commits=0;end
      def onTransactionCommit(_model);@commits+=1;end
    end.new
    @model.add_observer(observer)
    Host.native_model_state('items'=>[],'event'=>'commit','live_uids'=>[])
    assert_equal 1,observer.commits
  end
  def test_plugin_timer_can_fetch_native_context_without_creating_history
    Bridge.snapshot={'native_context'=>[item]}
    watch=EntitiesWatch.new;@model.entities.add_observer(watch)
    Host.native_model_state('items'=>[],'event'=>'commit','live_uids'=>['a'],'added_uids'=>['a'])
    observed=[]
    UI.start_timer(0) { observed << Sketchup.active_model.entities.to_a.grep(Sketchup::Group).size }
    UI.run_due_timers
    assert_equal [1],observed
    assert_equal 1,watch.added.size
    UI.start_timer(0) { Sketchup.active_model.entities.to_a }
    UI.run_due_timers
    assert_equal 1,watch.added.size
    assert_equal 0,@model.operation_depth
    assert_empty Bridge.events.select { |e| %w[upsert removed surface_patch face_erased].include?(e['op']) }
  end
end
