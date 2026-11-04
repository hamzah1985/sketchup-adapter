# Model-wide enumeration is lazy, read-only and populated before an operation's
# snapshot. Importing selection alone must not make unselected geometry vanish.
module Host
  class << self
    def with_extension_context
      previous=@extension_context_depth.to_i
      @extension_context_depth=previous+1
      yield
    ensure
      @extension_context_depth=previous
    end
    def deliver_native_added(uid, entity)
      return unless (@native_pending_added || {}).delete(uid.to_s)
      entities=Sketchup.active_model.entities
      entities.bridge_deliver(:onElementAdded,entities,entity)
    end
    def ensure_native_context
      owner=false
      return unless @extension_context_depth.to_i>0
      return if @fetching_native_context || @complete_native_context
      owner=true
      @fetching_native_context=true
      response=Bridge.call('scene_snapshot')
      return unless response.is_a?(Hash) && response['native_context'].is_a?(Array)
      added=[]
      Sketchup.silence_bridge_events do
        model=Sketchup.active_model
        items=response['native_context']
        items.each do |item|
          next unless %w[group bogdan wc].include?(item['kind'])
          uid=item['uid'].to_s
          rid=(@uid_to_rid || {})[uid]
          next if rid && @rid_map[rid] && @rid_map[rid].valid?
          snapshot=item['geometry']
          next unless snapshot
          group=build_pick_entity(snapshot,model.entities,0)
          next unless group
          group.instance_variable_set(:@bridge_copy_parent,model.entities)
          @proxy_groups << group
          rid=group.entityID
          @proxy_rids[rid]=true;@proxy_group_uids[rid]=uid
          (@uid_to_rid ||= {})[uid]=rid;@rid_map[rid]=group
          @sent_digest[rid]=Digest::SHA1.hexdigest(JSON.generate(export_container(group)))
          Bridge.notify('bind','uid'=>uid,'rid'=>rid)
          added << [uid,group]
        end
        import_cursor_context(items)
        import_native_edges(items)
      end
      @complete_native_context=true
      added.each { |uid,group| deliver_native_added(uid,group) }
    ensure
      @fetching_native_context=false if owner
    end
  end
  module NativeContext
    def sync(*args)
      previous=@extension_context_depth.to_i
      @extension_context_depth=0
      super
    ensure
      @extension_context_depth=previous
    end
    def set_selection(*args)
      @complete_native_context=false
      super
    end
    def reset_document(*args)
      @complete_native_context=false
      @proxy_entities=nil
      super
    end
    def dispatch(message)
      previous=@extension_context_depth.to_i
      @extension_context_depth=previous+1 if %w[command callback menu_click tool_event].include?(message['op'])
      super
    ensure
      @extension_context_depth=previous
    end
  end
  singleton_class.prepend(NativeContext)
end
module Sketchup
  module NativeContextModel
    def entities
      Host.ensure_native_context
      @entities
    end
    def active_entities
      Host.ensure_native_context
      super
    end
    def start_operation(*args)
      Host.ensure_native_context
      super
    end
  end
  Model.prepend(NativeContextModel)
end
