# Explicit compatibility dependencies for verified original module versions.
# They run original initialization and checks; no source/default/license rewrite.
module SketchupAdapter
  module ModuleDependencies
    RULES = {
      'frame2.rbs' => {
        'sha256'=>'ca02e74ec1eb84ef60a3946469c77de95741d8722eb10f878a9e258858b5d379',
        'requires'=>{'frame1.rbs'=>'fa7a11ea4d277d2ead05eecf1680bc0d9d185061567f5cc53ab2feb42d2747d0'}
      }
    }.freeze
    module_function

    def prerequisites(path, rules=RULES)
      path=File.expand_path(path)
      rule=rules[File.basename(path).downcase]
      return [] unless rule && Digest::SHA256.file(path).hexdigest==rule.fetch('sha256')
      rule.fetch('requires').map do |name,digest|
        dependency=File.expand_path(name,File.dirname(path))
        unless File.dirname(dependency)==File.dirname(path) && File.file?(dependency) && Digest::SHA256.file(dependency).hexdigest==digest
          raise LoadError,"Verified compatibility dependency missing or changed: #{name}"
        end
        dependency
      end
    end

    def prepare(path)
      prerequisites(path).each do |dependency|
        # require is idempotent. A later original load of the selected module
        # still replaces the shared method definitions in the expected order.
        Sketchup.require(dependency)
      end
    end
  end
end
