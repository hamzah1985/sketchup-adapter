require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
class TimerDueCancellation < Minitest::Test
 def setup;UI.timers.clear;end
 def test_due_timer_canceled_by_prior_callback_does_not_fire
  events=[];second=nil
  UI.start_timer(0,false){events<<:first;UI.stop_timer(second)}
  second=UI.start_timer(0,false){events<<:canceled}
  UI.run_due_timers;assert_equal [:first],events
 end
 def test_repeating_timer_canceled_before_turn_does_not_resurrect
  events=[];second=nil
  UI.start_timer(0,false){UI.stop_timer(second)}
  second=UI.start_timer(0,true){events<<:canceled}
  UI.run_due_timers;assert_empty events;refute UI.timers.key?(second)
 end
 def test_unrelated_due_timer_still_runs
  events=[];second=nil
  UI.start_timer(0,false){UI.stop_timer(second)}
  second=UI.start_timer(0,false){events<<:canceled}
  UI.start_timer(0,false){events<<:unrelated}
  UI.run_due_timers;assert_equal [:unrelated],events
 end
 def test_timer_scheduled_by_callback_runs_on_next_tick
  events=[];UI.start_timer(0,false){events<<:first;UI.start_timer(0,false){events<<:new}}
  UI.run_due_timers;assert_equal [:first],events;UI.run_due_timers;assert_equal [:first,:new],events
 end
 def test_global_repeating_timer_is_not_discarded_by_unrelated_cancel
  events=[];dead=UI.start_timer(100,false){}
  keep=UI.start_timer(0,true){events<<:global};UI.stop_timer(dead)
  UI.run_due_timers;assert_equal [:global],events;assert UI.timers.key?(keep)
 end
 def test_repeating_timer_can_cancel_itself
  events=[];id=nil;id=UI.start_timer(0,true){events<<:once;UI.stop_timer(id)}
  UI.run_due_timers;UI.run_due_timers;assert_equal [:once],events;refute UI.timers.key?(id)
 end
 def test_replaced_timer_object_does_not_execute_retired_callback
  events=[];second=nil
  UI.start_timer(0,false) do
   old=UI.timers.fetch(second)
   UI.timers[second]=old.merge(block:proc{events<<:replacement})
  end
  second=UI.start_timer(0,false){events<<:retired}
  UI.run_due_timers;assert_empty events
  UI.run_due_timers;assert_equal [:replacement],events
 end

 def test_nested_dispatch_does_not_double_fire_an_already_rescheduled_repeater
  events=[]
  UI.start_timer(0,false){events<<:outer;UI.run_due_timers}
  id=UI.start_timer(0,true){events<<:repeat};UI.timers[id][:every]=60
  UI.run_due_timers;assert_equal [:outer,:repeat],events
 end
 def test_in_place_future_reschedule_prevents_stale_due_dispatch
  events=[];id=nil
  UI.start_timer(0,false){UI.timers.fetch(id)[:at]=Time.now.to_f+60}
  id=UI.start_timer(0,true){events<<:incorrect}
  UI.run_due_timers;assert_empty events;assert UI.timers.key?(id)
 end
 def test_in_place_new_due_deadline_waits_for_next_dispatch
  events=[];id=nil
  UI.start_timer(0,false){UI.timers.fetch(id)[:at]=Time.now.to_f-1}
  id=UI.start_timer(0,false){events<<:later}
  UI.run_due_timers;assert_empty events
  UI.run_due_timers;assert_equal [:later],events
 end
 def test_active_repeater_cannot_reenter_itself_even_after_deadline
  events=[];id=nil
  id=UI.start_timer(0,true) do
   events<<:entered
   if events.length==1
    UI.timers[id][:at]=Time.now.to_f-1
    UI.run_due_timers
   else
    UI.stop_timer(id)
   end
  end
  UI.run_due_timers;assert_equal [:entered],events
  UI.run_due_timers;assert_equal [:entered,:entered],events;refute UI.timers.key?(id)
 end
 def test_same_id_replacement_waits_until_active_callback_returns
  events=[];id=nil
  id=UI.start_timer(0,true) do
   events<<:old
   UI.timers[id]=UI.timers.fetch(id).merge(at:Time.now.to_f-1,repeat:false,block:proc{events<<:new})
   UI.run_due_timers
  end
  UI.run_due_timers;assert_equal [:old],events
  UI.run_due_timers;assert_equal [:old,:new],events
 end
 def test_self_cancellation_does_not_cancel_new_distinct_timer
  events=[];id=nil
  id=UI.start_timer(0,true){events<<:old;UI.stop_timer(id);UI.start_timer(0,false){events<<:new}}
  UI.run_due_timers;assert_equal [:old],events
  UI.run_due_timers;assert_equal [:old,:new],events
 end

 def test_exception_does_not_leave_repeating_timer_locked
  events=[];id=nil;old_logger=Sketchup.method(:log_exc)
  Sketchup.define_singleton_method(:log_exc){|*_|nil}
  id=UI.start_timer(0,true){events<<:run;raise 'injected' if events.length==1}
  UI.run_due_timers;UI.timers[id][:at]=Time.now.to_f-1;UI.run_due_timers
  assert_equal [:run,:run],events
 ensure
  Sketchup.define_singleton_method(:log_exc,old_logger) if old_logger
 end

 def test_active_repeater_skipped_in_nested_dispatch_while_unrelated_timer_runs
  events=[];id=nil
  id=UI.start_timer(0,true) do
   events<<:repeat
   if events.length==1
    UI.timers[id][:at]=Time.now.to_f-1
    UI.start_timer(0,false){events<<:unrelated}
    UI.run_due_timers
   else
    UI.stop_timer(id)
   end
  end
  UI.run_due_timers;assert_equal [:repeat,:unrelated],events;assert UI.timers.key?(id)
  UI.run_due_timers;assert_equal [:repeat,:unrelated,:repeat],events;refute UI.timers.key?(id)
 end

end
