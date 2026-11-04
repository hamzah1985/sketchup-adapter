# Version-scoped routes from obsolete menu module names to original variants.
# The original loader and target module still execute all their normal checks.
module SketchupAdapter
  module LegacyModules
    PROFILE={
      'menu'=>'1001promenu.rbs',
      'sha256'=>'eaf25f25e3fb858a9969cc94ca3c2de82e8b7ffd3c1b505d4c8d5ac6cc2fbf8e',
      'aliases'=>{
        '/staircase1'=>['/staircase1_0','c75a3fcf76e677d2a6a49602ab777277f3726a51496784f023540037cd208ff3'],
        '/staircase4'=>['/staircase4_1','ea403791afefdb1c2cad352fac6dd4b7c1d120e07a0f0c68e2e0165728df602e'],
        '/spiralstair'=>['/spiralstair_1','e6ae5cf902aa9a5fdc0ce12ece5f6ac66d24d7db77f3af307cee7f7d539e4728']
      }
    }.freeze
    module_function

    def prepare(path,profile=PROFILE)
      path=File.expand_path(path)
      return false unless File.basename(path).casecmp(profile['menu']).zero?
      return false unless Digest::SHA256.file(path).hexdigest==profile['sha256']
      (@roots ||= {})[File.dirname(path).tr('\\','/').downcase]=[path,profile]
      Object.prepend(LoaderRoute) unless Object.ancestors.include?(LoaderRoute)
      true
    end

    def route(root,name)
      return name unless root.is_a?(String) && name.is_a?(String)
      root=File.expand_path(root)
      menu,profile=(@roots || {})[root.tr('\\','/').downcase]
      return name unless profile && profile['aliases'].key?(name)
      # An actual legacy module supplied by the vendor takes precedence.
      return name if %w[.rbs .rb].any? { |extension| File.file?(root+name+extension) }
      return name unless File.file?(menu) && Digest::SHA256.file(menu).hexdigest==profile['sha256']
      target,digest=profile['aliases'][name]
      path=root+target+'.rbs'
      return name unless File.file?(path) && Digest::SHA256.file(path).hexdigest==digest
      target
    end

    module LoaderRoute
      private
      def gh_launch_1001pro_tool(name)
        super(SketchupAdapter::LegacyModules.route($GH1001pro_path,name))
      end
    end
  end
end
