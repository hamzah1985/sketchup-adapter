# SPDX-License-Identifier: GPL-3.0-or-later
# Generic extension loading. The inherited transport and geometry implementation
# remain separate so plugin-specific fixes never define loading policy.
require 'set'
require 'tmpdir'
require_relative 'universal_api'
require_relative 'loose_geometry'
require_relative 'rbs'
require_relative 'module_dependencies'
require_relative 'legacy_modules'
require_relative 'operation_contracts'

module SketchupAdapter
  class UnsupportedFeature < NotImplementedError; end
  @roots = []
  @results = []
  @gaps = {}
  class << self
    attr_accessor :roots, :current_plugin, :current_root, :data_root
    attr_reader :results, :gaps

    def diagnostic(error, where = nil)
      result = {'class'=>error.class.name, 'message'=>error.message.to_s,
                'trace'=>(error.backtrace || []).first(12), 'where'=>where,
                'plugin_id'=>current_plugin && current_plugin['id']}
      if error.is_a?(NoMethodError)
        result['api'] = "#{error.receiver.is_a?(Module) ? error.receiver.name : error.receiver.class.name}#{error.receiver.is_a?(Module) ? '.' : '#'}#{error.name}"
      elsif error.is_a?(NameError)
        result['api'] = error.name.to_s
      end
      result
    end

    def gap(feature, detail = nil)
      key = [current_plugin && current_plugin['id'], feature, detail]
      return if @gaps[key]
      @gaps[key] = true
      Bridge.notify('api_gap', 'plugin_id'=>key[0], 'api'=>feature,
                    'message'=>detail || 'Unsupported feature', 'status'=>'unsupported')
    end

    def resolve(path, mode = :require)
      path = path.to_s
      candidates = if File.extname(path).empty?
        (mode == :require ? %w[.rbe .rbs .rb] : %w[.rb .rbe .rbs]).map { |ext| path + ext }
      else
        [path]
      end
      search = [current_root, *roots, *$LOAD_PATH].compact.uniq
      search.unshift(Dir.pwd) if path.start_with?('./', '../')
      candidates.each do |candidate|
        paths = Pathname.new(candidate).absolute? ? [candidate] : search.map { |root| File.expand_path(candidate, root) }
        found = paths.find { |full| File.file?(full) }
        next unless found
        if File.extname(found).downcase == '.rbe'
          gap('Sketchup.require.encrypted', found)
          raise UnsupportedFeature, "RBE code requires a loader that this adapter does not implement: #{found}"
        end
        return File.expand_path(found)
      end
      raise LoadError, "cannot load such file -- #{path} (searched #{search.join(', ')})"
    end

    def load_plugins(config)
      self.roots = Array(config['roots']).map { |p| File.expand_path(p) }.uniq
      self.data_root = config['data_root']
      roots.reverse_each { |root| $LOAD_PATH.unshift(root) unless $LOAD_PATH.include?(root) }
      Sketchup.plugins_dir = roots.first || Dir.pwd
      Array(config['plugins']).each do |plugin|
        self.current_plugin = plugin
        self.current_root = File.expand_path(plugin['root'])
        before_commands = UI.commands.length
        before_geometry = Sketchup::OperationSnapshot.new(Sketchup.active_model)
        before_depth = Sketchup.active_model.operation_depth
        Bridge.notify('extension_loading', 'plugin_id'=>plugin['id'], 'name'=>plugin['name'])
        begin
          Array(plugin['loaders']).each do |loader|
            full = File.expand_path(loader, current_root)
            raise LoadError, "Loader outside plugin directory: #{loader}" unless full.start_with?(current_root + File::SEPARATOR)
            Kernel.require(resolve(full))
          end
          result = {'plugin_id'=>plugin['id'], 'name'=>plugin['name'], 'status'=>'loaded',
                    'commands'=>UI.commands.length-before_commands, 'compatibility'=>'startup_only'}
          @results << result
          Bridge.notify('extension_loaded', result)
        rescue StandardError, ScriptError, UnsupportedFeature, SystemExit => error
          # Failed initialization cannot leak half-built geometry. Ruby module
          # definitions cannot be unloaded reliably: restart after changing the
          # enabled set. Existing successfully loaded plugins keep running.
          while Sketchup.active_model.operation_depth > before_depth
            Sketchup.active_model.abort_operation
          end
          before_geometry.restore(Sketchup.active_model)
          UI.commands[before_commands..-1].to_a.each { |command| command.instance_variable_set(:@adapter_failed, true) }
          result = diagnostic(error, 'load').merge('name'=>plugin['name'], 'status'=>'failed')
          @results << result
          Bridge.notify('extension_error', result)
        ensure
          self.current_plugin = nil
          self.current_root = nil
        end
      end
      Host.install_ingetrazo_overrides_if_available
      SketchupAdapter::OperationContracts.install
      loaded = @results.count { |item| item['status'] == 'loaded' }
      Bridge.notify('capabilities', capabilities)
      Bridge.notify('ready', 'commands'=>UI.commands.reject { |c| c.instance_variable_get(:@adapter_failed) }.map(&:to_h),
                    'menu'=>{'name'=>'SketchUp Plugins','items'=>UI.instance_variable_get(:@menus).values.flat_map { |menu| menu.name=='Extensions' ? menu.to_h['items'] : [{'submenu'=>menu.to_h}] }}, 'version'=>'SketchUp Adapter 0.1.0',
                    'build'=>1, 'loaded'=>loaded, 'failed'=>@results.length-loaded,
                    'results'=>@results, 'protocol'=>1)
    end

    def capabilities
      classes = {}
      [Sketchup, Geom, UI].each do |namespace|
        namespace.constants(false).sort_by(&:to_s).each do |name|
          value = namespace.const_get(name)
          next unless value.is_a?(Module)
          classes["#{namespace.name}::#{name}"] = {
            'instance_methods'=>value.instance_methods(false).map(&:to_s).sort,
            'class_methods'=>value.singleton_methods(false).map(&:to_s).sort
          }
        end
      end
      {'adapter_version'=>'0.1.0', 'ruby_version'=>RUBY_VERSION, 'ruby_platform'=>RUBY_PLATFORM,
       'api_target'=>'SketchUp Ruby API (partial)', 'classes'=>classes,
       'legacy_rbs'=>'RBS1.0 reader; requires locally configured format key',
       'unsupported'=>['RBE execution', 'SketchUp C API / in-process renderer binaries',
                        'Full SketchUp geometry kernel parity', 'Native edit-context synchronization',
                        'All rendering, scene and dimension APIs'],
       'classes_are_inventory_not_conformance'=>true}
    end
  end
end

require 'pathname'
module Sketchup
  class ExtensionsManager
    include Enumerable
    def initialize; @items=[]; end
    def each(&block); return enum_for(:each) unless block; @items.each(&block); end
    def [](key); key.is_a?(Integer) ? @items[key] : @items.find { |item| item.name == key.to_s }; end
    def register(extension); @items << extension unless @items.include?(extension); end
    def size; @items.size; end
    alias length size
    def keys; @items.map(&:name); end
  end
  class << self
    def extensions; @adapter_extensions ||= ExtensionsManager.new; end
    def register_extension(extension, load_on_start = true)
      raise TypeError, 'Expected SketchupExtension' unless extension.is_a?(SketchupExtension)
      extension.instance_variable_set(:@registered, true)
      extension.instance_variable_set(:@load_on_start, !!load_on_start)
      extension.instance_variable_set(:@adapter_root, SketchupAdapter.current_root || plugins_dir)
      extension.instance_variable_set(:@extension_path, caller_locations(1,1).first.absolute_path)
      extensions.register(extension)
      extension.load_now if load_on_start
      true
    end
    def require(path)
      resolved=SketchupAdapter.resolve(path,:require)
      SketchupAdapter::ModuleDependencies.prepare(resolved)
      SketchupAdapter::LegacyModules.prepare(resolved)
      File.extname(resolved).downcase=='.rbs' ? SketchupAdapter::RBS.require(resolved) : Kernel.require(resolved)
    end
    def load(path)
      resolved=SketchupAdapter.resolve(path,:load)
      SketchupAdapter::ModuleDependencies.prepare(resolved)
      SketchupAdapter::LegacyModules.prepare(resolved)
      File.extname(resolved).downcase=='.rbs' ? SketchupAdapter::RBS.load(resolved) : Kernel.load(resolved)
      true
    end
    def find_support_file(name, directory = '')
      roots = [SketchupAdapter.current_root, *SketchupAdapter.roots, plugins_dir].compact.uniq
      if directory.to_s.empty? && name.to_s.tr('\\','/').sub(%r{/+\z},'').casecmp('Plugins').zero?
        return roots.find { |root| File.directory?(root) }
      end
      roots.each do |root|
        # Plugins is a logical support directory, not a nested Plugins/Plugins.
        dir = directory.to_s.tr('\\','/').sub(%r{/+\z},'').casecmp('Plugins').zero? ? '' : directory.to_s
        relative=dir.empty? ? name.to_s : File.join(dir,name.to_s)
        relative=relative.tr('\\','/').sub(%r{\APlugins/}i,'')
        path = File.expand_path(relative, root)
        return path if File.exist?(path)
      end
      nil
    end
    def find_support_files(filename, directory = '')
      SketchupAdapter.roots.filter_map { |root|
        dir=directory.to_s.tr('\\','/').sub(%r{/+\z},'').casecmp('Plugins').zero? ? '' : directory.to_s
        path = File.expand_path(dir.empty? ? filename.to_s : File.join(dir,filename.to_s), root)
        path if File.file?(path)
      }
    end
    def defaults_path
      base = SketchupAdapter.data_root || File.join(ENV['APPDATA'] || Dir.home, 'IngeTrazo', 'sketchup_adapter')
      FileUtils.mkdir_p(base)
      File.join(base, 'ruby-preferences.json')
    end
    def register_autoclassify_callback(*); SketchupAdapter.gap('Sketchup.register_autoclassify_callback'); false; end
  end
end

class SketchupExtension
  attr_reader :extension_path
  def initialize(name, loader)
    @name=name; @loader=loader; @loaded=false; @registered=false; @load_on_start=false
  end
  def registered?; !!@registered; end
  def loaded?; !!@loaded; end
  def load_on_start?; !!@load_on_start; end
  def check; @load_on_start=true; load_now; end
  def uncheck; @load_on_start=false; true; end
  def load_now
    return false if @loaded
    previous = SketchupAdapter.current_root
    SketchupAdapter.current_root = @adapter_root || previous
    Sketchup.require(@loader)
    @loaded=true
    true
  ensure
    SketchupAdapter.current_root = previous if defined?(previous)
  end
end

$sketchup_adapter_loaded_files ||= Set.new
def file_loaded?(filename); $sketchup_adapter_loaded_files.include?(filename.to_s.tr('\\','/').downcase); end
def file_loaded(filename); $sketchup_adapter_loaded_files.add(filename.to_s.tr('\\','/').downcase); nil; end

def add_separator_to_menu(name)
  $sketchup_adapter_menu_separators ||= Set.new
  return if $sketchup_adapter_menu_separators.include?(name)
  UI.menu(name).add_separator
  $sketchup_adapter_menu_separators.add(name)
  nil
end

def inputbox(*arguments)
  UI.inputbox(*arguments)
rescue ArgumentError => error
  UI.messagebox(error.message)
  retry unless arguments.empty?
end

def require_all(directory)
  $LOAD_PATH << directory unless $LOAD_PATH.include?(directory)
  Dir[File.join(directory,'*.{rbe,rbs,rb}')].sort.each { |path| Sketchup.require(path) }
  nil
end

def show_ruby_panel; Sketchup.send_action('showRubyPanel:'); end

module Host
  class << self
    def install_ingetrazo_overrides_if_available; install_ingetrazo_overrides; end
    alias legacy_load_plugins load_plugins
    def load_plugins(directory, loaders)
      return SketchupAdapter.load_plugins(loaders) if loaders.is_a?(Hash)
      config = {'roots'=>[directory], 'plugins'=>Array(loaders).map { |loader|
        {'id'=>loader, 'name'=>loader, 'root'=>directory, 'loaders'=>[loader]}
      }}
      SketchupAdapter.load_plugins(config)
    end
  end
end

# Capture genuine API failures without pretending they succeeded. Raised and
# recovered exceptions are labelled accordingly; they are not plugin failures.
SketchupAdapter::GAP_TRACE = TracePoint.new(:raise) do |trace|
  error = trace.raised_exception
  next unless error.is_a?(NoMethodError) || error.is_a?(NameError) || error.is_a?(SketchupAdapter::UnsupportedFeature)
  if error.is_a?(NoMethodError)
    receiver = error.receiver
    owner = receiver.is_a?(Module) ? receiver.name.to_s : receiver.class.name.to_s
    next unless owner.start_with?('Sketchup', 'Geom', 'UI')
  elsif error.is_a?(NameError)
    next unless error.message.match?(/(?:Sketchup|Geom|UI)::/)
  end
  data = SketchupAdapter.diagnostic(error, 'raised_exception')
  feature = data['api'] || error.class.name
  key = [data['plugin_id'], feature, trace.path, trace.lineno]
  next if SketchupAdapter.gaps[key]
  SketchupAdapter.gaps[key] = true
  Bridge.notify('api_gap', data.merge('status'=>'raised_may_be_recovered'))
end
SketchupAdapter::GAP_TRACE.enable
