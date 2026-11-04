# Preserve object identity when a SketchUp operation aborts. Merely popping
# an operation flag left failed generators' partial geometry in the worker.
module Sketchup
  class OperationSnapshot
    SKIP = %i[@ops @observers @obs @bridge_observers @bridge_event_stack @active_view @tools @overlays @generation_faces @generation_time @generation_label].freeze
    def initialize(model)
      @states = {}
      visit(model)
    end
    def containers(value)
      case value
      when Array then value.map { |v| containers(v) }
      when Hash
        value.each_with_object(value.dup.clear) { |(k,v),h| h[k] = containers(v) }
      when String then value.dup
      else value
      end
    end
    def visit(value)
      # Face/edge/vertex links form long cyclic graphs. Traversing that graph
      # recursively exhausts Ruby's stack on detailed models and previews.
      pending = [value]
      seen_containers = {}
      until pending.empty?
        item = pending.pop
        if item.is_a?(Array) || item.is_a?(Hash)
          next if seen_containers[item.object_id]
          seen_containers[item.object_id] = true
          if item.is_a?(Array)
            pending.concat(item)
          else
            item.each { |k,v| pending << k << v }
          end
          next
        end
        next unless item.class.name.to_s.start_with?('Sketchup::','Geom::')
        next if @states.key?(item)
        vars = item.instance_variables - SKIP
        @states[item] = vars.to_h { |name| [name,containers(item.instance_variable_get(name))] }
        vars.each { |name| pending << item.instance_variable_get(name) }
      end
    end
    def restore(model)
      current = self.class.new(model)
      current.instance_variable_get(:@states).each_key do |object|
        object.mark_deleted! if object.is_a?(Entity) && !@states.key?(object)
      end
      @states.each do |object,vars|
        (object.instance_variables - vars.keys - SKIP).each { |name| object.remove_instance_variable(name) }
        vars.each { |name,value| object.instance_variable_set(name,containers(value)) }
      end
    end
  end

  class Model
    def operation_depth; @ops.length; end
    def bridge_operation_token; @ops.last; end
    def committed_revision; @committed_revision || 0; end
    def start_operation(*_args)
      # SketchUp operations are sequential. Starting another closes the old
      # operation; a later abort must not roll back that committed geometry.
      commit_operation unless @ops.empty?
      @ops << OperationSnapshot.new(self)
      @generation_faces=0
      @generation_label=_args[0].to_s
      @generation_time=Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @cancel_check_time=0.0
      Bridge.notify('progress','phase'=>'generating','done'=>0,'name'=>@generation_label,'tool'=>defined?(Host) ? Host.active_tool_id : nil)
      true
    end
    def commit_operation
      generation_progress(true) unless @ops.empty?
      @ops.pop
      @committed_revision = committed_revision + 1
      true
    end
    def abort_operation
      snapshot = @ops.pop
      snapshot.restore(self) if snapshot
      Host.restore_cursor_context if defined?(Host) && Host.respond_to?(:restore_cursor_context)
      Host.restore_native_edges if defined?(Host) && Host.respond_to?(:restore_native_edges)
      @committed_revision = committed_revision + 1
      true
    end
    def note_generated_face
      return if @ops.empty? || (Sketchup.respond_to?(:bridge_events_silent?) && Sketchup.bridge_events_silent?)
      @generation_faces=(@generation_faces || 0)+1
      generation_progress
    end
    def generation_progress(force=false)
      now=Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if force || now-(@cancel_check_time || 0)>=0.05
        @cancel_check_time=now
        Host.check_generation_cancel! if defined?(Host) && Host.respond_to?(:check_generation_cancel!)
      end
      return unless force || @generation_faces.to_i%128==0 || now-(@generation_time || now)>=0.1
      @generation_time=now
      Bridge.notify('progress','phase'=>'generating','done'=>@generation_faces.to_i,'name'=>@generation_label,'tool'=>defined?(Host) ? Host.active_tool_id : nil)
    end
  end
end
