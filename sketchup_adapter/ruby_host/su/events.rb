# Registered observers must receive the events advertised by the API. No
# synthetic transaction is emitted when native selection copies are read.
module Sketchup
  module Observable
    def add_observer(observer)
      list=(@bridge_observers ||= [])
      list << observer unless list.include?(observer)
      true
    end
    def remove_observer(observer);!!(@bridge_observers && @bridge_observers.delete(observer));end
    def bridge_event(method,*args)
      return if Sketchup.bridge_events_silent?
      return if Array(@bridge_observers).empty?
      stack=Sketchup.active_model.instance_variable_get(:@bridge_event_stack)
      if stack && !stack.empty?
        stack.last[[object_id,method,args.map { |a| a.respond_to?(:entityID) ? a.entityID : a }]]=[self,method,args]
        return
      end
      bridge_deliver(method,*args)
    end
    def bridge_deliver(method,*args)
      Array(@bridge_observers).dup.each do |observer|
        begin
          observer.public_send(method,*args) if observer.respond_to?(method)
        rescue StandardError=>error
          Sketchup.log_exc("observer #{method}",error)
        end
      end
    end
  end
  [Entity,Entities,DefinitionList,Materials,Layers].each { |klass| klass.prepend(Observable) }
  def self.bridge_events_silent?;@bridge_events_silent.to_i>0;end
  def self.silence_bridge_events
    @bridge_events_silent=@bridge_events_silent.to_i+1
    yield
  ensure
    @bridge_events_silent-=1
  end

  module EntityEvents
    def mark_deleted!
      alive=valid?
      result=super
      if alive
        bridge_event(:onEraseEntity,self)
        parent_entities.bridge_event(:onElementRemoved,parent_entities,entityID) if parent_entities
      end
      result
    end
    def set_attribute(*args)
      result=super
      bridge_changed
      result
    end
    def delete_attribute(*args)
      result=super
      bridge_changed if result
      result
    end
    def bridge_changed
      return if Sketchup.bridge_events_silent?
      return if !@bridge_observers && (!parent_entities || !parent_entities.instance_variable_get(:@bridge_observers))
      bridge_event(:onChangeEntity,self)
      parent_entities.bridge_event(:onElementModified,parent_entities,self) if parent_entities
    end
  end
  Entity.prepend(EntityEvents)

  module EntitiesEvents
    # These are the primitive insertion paths; add_face/add_line and mesh
    # imports call them too. Only new entities produce an added event.
    %i[edge add_face_raw add_group add_instance].each do |method|
      define_method(method) do |*args,&block|
        before=raw_items.length
        result=super(*args,&block)
        bridge_event(:onElementAdded,self,result) if result && raw_items.length>before
        result
      end
    end
    def transform_entities(transform,*list)
      result=super
      list.flatten.uniq.each { |entity| entity.bridge_changed if entity.respond_to?(:bridge_changed) }
      result
    end
  end
  Entities.prepend(EntitiesEvents)

  module DrawingEvents
    %i[material= back_material= hidden= visible= layer=].each do |method|
      define_method(method) do |value|
        result=super(value)
        bridge_changed
        result
      end
    end
  end
  Drawingelement.prepend(DrawingEvents)

  module TransactionEvents
    def start_operation(*args)
      result=super
      (@bridge_event_stack ||= []) << {}
      observers.dup.each do |o|
        begin;o.onTransactionStart(self) if o.respond_to?(:onTransactionStart)
        rescue StandardError=>e;Sketchup.log_exc('transaction observer',e);end
      end
      result
    end
    def commit_operation
      result=super
      events=(@bridge_event_stack ||= []).pop || {}
      if @bridge_event_stack.empty?
        events.each_value { |target,method,args| target.bridge_deliver(method,*args) }
      else
        @bridge_event_stack.last.merge!(events)
      end
      observers.dup.each do |o|
        begin;o.onTransactionCommit(self) if o.respond_to?(:onTransactionCommit);rescue StandardError=>e;Sketchup.log_exc('transaction observer',e);end
      end
      result
    end
    def abort_operation
      result=super
      (@bridge_event_stack ||= []).pop
      observers.dup.each do |o|
        begin;o.onTransactionAbort(self) if o.respond_to?(:onTransactionAbort);rescue StandardError=>e;Sketchup.log_exc('transaction observer',e);end
      end
      result
    end
  end
  Model.prepend(TransactionEvents)
end
