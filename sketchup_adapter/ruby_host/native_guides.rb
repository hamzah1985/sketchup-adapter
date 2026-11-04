# Construction points/lines are native guides, separate from polygon geometry.
module Host
  class << self
    def native_guide_snapshot
      @guide_entities ||= {}
      result=[]
      walk=lambda do |entities,transform,path,visible|
        entities.each do |entity|
          next unless entity.valid?
          shown=visible && !hidden_in_native_view?(entity)
          if entity.is_a?(Sketchup::ConstructionPoint) || entity.is_a?(Sketchup::ConstructionLine)
            key=(path+[entity.entityID]).join(':')
            @guide_entities[key]={entity:entity,parent:entities}
            next unless shown
            point=Geom::Point3d.new(entity.position.to_a).transform(transform)
            data={'id'=>key,'point'=>m(point),'layer'=>entity.layer.name}
            if entity.is_a?(Sketchup::ConstructionLine)
              direction=Geom::Vector3d.new(entity.direction.to_a).transform(transform)
              data['direction']=direction.to_a if direction.length>1e-12
            end
            result << data
          elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
            walk.call(entity.entities,transform*entity.transformation,path+[entity.entityID],shown)
          end
        end
      end
      walk.call(Sketchup.active_model.entities,Geom::Transformation.new,[],true)
      result
    end

    def sync_native_guides
      items=native_guide_snapshot
      digest=JSON.generate(items)
      @sent_guide_digest ||= '[]'
      return if digest==@sent_guide_digest
      @sent_guide_digest=digest
      Bridge.notify('guide_patch','items'=>items)
    end

    def align_native_guides(items)
      present=Array(items).to_h { |data| [data['id'],data] }
      (@guide_entities || {}).each do |key,record|
        entity=record[:entity];parent=record[:parent]
        if present[key]
          unless parent.raw_items.include?(entity)
            entity.instance_variable_set(:@deleted,false)
            parent.raw_items << entity
          end
          point=Geom::Point3d.new(present[key]['point'].map { |v| v/INCH })
          # Root guides use model coordinates. Nested guide movement through
          # native group editing remains outside this transport's guarantee.
          entity.instance_variable_set(:@position,point) if !key.include?(':')
        elsif parent.raw_items.include?(entity)
          parent.raw_items.delete(entity)
          entity.instance_variable_set(:@deleted,true)
        end
      end
      @sent_guide_digest=JSON.generate(native_guide_snapshot)
    end
  end
  module NativeGuideHistory
    def native_model_state(message)
      super
      align_native_guides(message['guides']) if message.key?('guides')
    end
    def reset_document
      super
      @guide_entities={};@sent_guide_digest='[]'
    end
  end
  singleton_class.prepend(NativeGuideHistory)
end
