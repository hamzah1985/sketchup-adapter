# Narrow contracts for legacy callbacks that finish geometry but omit commit.
# Unknown extensions and open interactive previews retain their own lifecycle.
module SketchupAdapter
  module OperationContracts
    TIG_VECTOR_SHA256='9a1291bc7d6f99e49486375b93c94e35ff2425c406066842dd7e12090771f563'.freeze
    module_function

    def finish_new_operation(model)
      before=model.bridge_operation_token
      result=yield
      after=model.bridge_operation_token
      model.commit_operation if after && !after.equal?(before)
      result
    end

    def install
      return unless defined?(ExtrudeTools::ExtrudeEdgesByVector)
      klass=ExtrudeTools::ExtrudeEdgesByVector
      return if klass.ancestors.include?(TigVectorCompletion)
      return unless verified?(klass)
      klass.prepend(TigVectorCompletion)
    end

    def verified?(klass)
      implementation=klass.instance_method(:create_geometry)
      implementation=implementation.super_method while implementation && implementation.owner!=klass
      source=implementation&.source_location&.first
      source && File.file?(source) && File.basename(source)=='extrudeEdgesByVector.rb' && Digest::SHA256.file(source).hexdigest==TIG_VECTOR_SHA256
    end

    module TigVectorCompletion
      def create_geometry(*args,&block)
        return super(*args,&block) unless SketchupAdapter::OperationContracts.verified?(ExtrudeTools::ExtrudeEdgesByVector)
        SketchupAdapter::OperationContracts.finish_new_operation(Sketchup.active_model) { super(*args,&block) }
      end
    end
  end
end
