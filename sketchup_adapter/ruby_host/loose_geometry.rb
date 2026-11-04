# SPDX-License-Identifier: GPL-3.0-or-later
# IngeTrazo's transport operates on groups. Root-level SketchUp faces and edges
# stay loose in the Ruby model and travel as a dedicated native group. Native
# undo/redo restores the loose collection; selection proxies never enter it.
module Host
  class << self
    def adapter_loose_items(model=Sketchup.active_model)
      proxy_faces=(@host_faces.values.map { |record| record[:face] }+
        model.entities.faces.select { |face| face.instance_variable_get(:@adapter_surface_token) }).uniq
      proxy_edges=(@host_edges + (@host_surface_edges || []) + proxy_faces.flat_map(&:edges)).uniq
      model.entities.to_a.select { |entity|
        entity.valid? && ((entity.is_a?(Sketchup::Face) && !proxy_faces.include?(entity)) ||
                         (entity.is_a?(Sketchup::Edge) && !proxy_edges.include?(entity) &&
                           !entity.instance_variable_get(:@adapter_surface_edge) &&
                           !entity.instance_variable_get(:@adapter_edge_token)))
      }
    end

    def adapter_loose_root(model)
      items=adapter_loose_items(model)
      return nil if items.empty?
      unless @adapter_loose_root && @adapter_loose_root.valid?
        definition=Sketchup::ComponentDefinition.new('SketchUp loose geometry',true)
        @adapter_loose_root=Sketchup::Group.new(definition)
        @adapter_loose_root.name='SketchUp loose geometry'
        @adapter_loose_root.set_attribute('sketchup_adapter','loose_root',true)
      end
      # The private export view references the original entities without
      # reparenting, moving, registering or mutating the model's geometry.
      @adapter_loose_root.definition.entities.instance_variable_set(:@items,items)
      @adapter_loose_root
    end
  end

  module LooseHistory
    def native_model_state(message)
      root=@adapter_loose_root
      item=Array(message['items']).find { |record| root && record['rid'].to_i==root.entityID }
      if root && (@uid_to_rid || {}).value?(root.entityID)
        current=adapter_loose_items
        if item.nil?
          @adapter_loose_archive=current unless current.empty?
          Sketchup.active_model.entities.raw_items.reject! { |entity| current.include?(entity) }
        elsif item['geometry']
          # Let the inherited identity-preserving importer reconstruct the
          # export view first; then attach those entities to the real root.
          super
          entities=root.definition.entities.to_a
          owner=Sketchup.active_model.entities
          owner.raw_items.reject! { |entity| current.include?(entity) || entity.equal?(root) }
          entities.each { |entity| entity.parent_entities=owner; owner.raw_items << entity }
          root.instance_variable_set(:@deleted,false)
          return
        elsif current.empty? && @adapter_loose_archive
          @adapter_loose_archive.each { |entity| Sketchup.active_model.entities.raw_items << entity }
        end
      end
      super
      # A transport container is never itself a Ruby document entity.
      Sketchup.active_model.entities.raw_items.delete(root) if root
    end

    def reset_document
      @adapter_loose_root=nil
      @adapter_loose_archive=nil
      super
    end
  end
  singleton_class.prepend(LooseHistory)
end
