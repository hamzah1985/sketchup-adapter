# A sync is one native history operation, even when its geometry is prepared
# asynchronously. Mark only batches that actually contain document edits.
module Bridge
  class << self
    alias_method :unbatched_notify, :notify
    def notify(op,data={})
      if @geometry_batch_depth.to_i>0 && %w[upsert removed face_erased surface_patch edge_patch guide_patch].include?(op)
        unless @geometry_batch_started
          unbatched_notify('geometry_batch_begin')
          @geometry_batch_started=true
        end
      end
      unbatched_notify(op,data)
    end
    def geometry_batch
      @geometry_batch_depth=@geometry_batch_depth.to_i+1
      yield
    ensure
      @geometry_batch_depth-=1
      if @geometry_batch_depth==0 && @geometry_batch_started
        @geometry_batch_started=false
        unbatched_notify('geometry_batch_end')
      end
    end
  end
end
module Host
  module AtomicNativeSync
    def sync(*args);Bridge.geometry_batch { super };end
    def set_selection(*args);Sketchup.silence_bridge_events { super };end
    def build_pick_entity(*args);Sketchup.silence_bridge_events { super };end
    def native_model_state(*args);Sketchup.silence_bridge_events { super };end
  end
  singleton_class.prepend(AtomicNativeSync)
  class << self
    def reset_document
      @rid_map.clear;@sent_digest.clear;@host_faces.clear;@host_edges.clear
      @cursor_surface_records={}
      @host_edge_records={}
      @pending.clear;@pick_targets.clear;@pick_entities=nil
      @proxy_rids.clear;@proxy_group_uids.clear
      @proxy_groups=[];@tools.clear;@tool_ids.clear;@active_tool_id=nil
      @uid_to_rid={} if instance_variable_defined?(:@uid_to_rid)
      @native_snapshot_digests={};@native_archived={}
      @native_surface_materials={}
      @native_pending_added={}
      Sketchup.reset_model!
      Bridge.notify('document_reset_done')
      Sketchup.observers.dup.each do |observer|
        begin
          observer.onNewModel(Sketchup.active_model) if observer.respond_to?(:onNewModel)
          observer.onActivateModel(Sketchup.active_model) if observer.respond_to?(:onActivateModel)
        rescue StandardError=>error
          Sketchup.log_exc('native document reset observer',error)
        end
      end
    end

    def native_model_state(message)
      @native_archived ||= {}
      @native_pending_added ||= {}
      Array(message['removed_uids']).each { |uid| @native_pending_added.delete(uid.to_s) }
      Array(message['added_uids']).each { |uid| @native_pending_added[uid.to_s]=true }
      removed=Array(message['removed_uids']).map(&:to_s)
      present=Array(message['items']).to_h { |item| [item['uid'].to_s,item] }
      live=message['live_uids'].is_a?(Array) ? message['live_uids'].map(&:to_s) : nil
      @native_pending_added.delete_if { |uid,_| !live.include?(uid) } if live
      (@uid_to_rid || {}).to_a.each do |uid,rid|
        next if @proxy_rids[rid] && (!live || live.include?(uid))
        entity=@rid_map[rid]
        if !present.key?(uid) && entity && entity.valid?
          if removed.include?(uid)
            entities=Sketchup.active_model.entities
            entities.bridge_deliver(:onElementRemoved,entities,entity.entityID)
          end
          @native_archived[uid]=entity
          Sketchup.active_model.entities.raw_items.delete(entity)
          entity.instance_variable_set(:@deleted,true)
          @rid_map.delete(rid);@sent_digest.delete(rid)
        end
      end
      present.each do |uid,item|
        rid=item['rid'].to_i
        @uid_to_rid ||= {}
        @uid_to_rid[uid]=rid
        entity=@rid_map[rid] || @native_archived.delete(uid)
        next unless entity
        unless entity.valid?
          entity.instance_variable_set(:@deleted,false)
          Sketchup.active_model.entities.raw_items << entity
          @proxy_groups << entity if @proxy_rids[rid] && !@proxy_groups.include?(entity)
        end
        if item['geometry']
          temporary=build_pick_entity(item['geometry'],Sketchup::Entities.new(Sketchup.active_model),0)
          entity.definition=temporary.definition
          temporary.erase!
          @native_snapshot_digests ||= {}
          @native_snapshot_digests[uid]=Digest::SHA1.hexdigest(JSON.generate(item['geometry']))
        end
        entity.transformation=xform_in(item['xform']) if item['xform']
        entity.hidden=!!item['hidden']
        @rid_map[rid]=entity
        @sent_digest[rid]=Digest::SHA1.hexdigest(JSON.generate(export_container(entity)))
      end
      method={'undo'=>:onTransactionUndo,'redo'=>:onTransactionRedo,'commit'=>:onTransactionCommit}[message['event']]
      return unless method
      model=Sketchup.active_model
      model.observers.dup.each do |observer|
        begin;observer.public_send(method,model) if observer.respond_to?(method)
        rescue StandardError=>error;Sketchup.log_exc('native history observer',error);end
      end
    end
  end
end
