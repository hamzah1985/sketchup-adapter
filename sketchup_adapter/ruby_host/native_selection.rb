# Selection edits are UI state, not native geometry or history operations.
module Host
  module NativeSelection
    def set_selection(*args)
      super
      @native_selection_ids=Sketchup.active_model.selection.map(&:entityID).sort
    end

    def sync(*args)
      super
      model=Sketchup.active_model
      return unless model.operation_depth.zero?
      selected=model.selection.to_a.select(&:valid?)
      ids=selected.map(&:entityID).sort
      return if @native_selection_ids.nil? || ids==@native_selection_ids
      @native_selection_ids=ids
      items=selected.filter_map do |entity|
        if (token=entity.instance_variable_get(:@adapter_surface_token))
          {'kind'=>'face','token'=>token}
        elsif (token=entity.instance_variable_get(:@adapter_edge_token))
          {'kind'=>'edge','token'=>token}
        elsif @rid_map[entity.entityID]
          {'kind'=>'group','rid'=>entity.entityID,'uid'=>(@proxy_group_uids || {})[entity.entityID]}
        end
      end
      Bridge.notify('selection_changed','items'=>items)
    end

    def reset_document(*args)
      @native_selection_ids=nil
      super
    end
  end
  singleton_class.prepend(NativeSelection)
end
