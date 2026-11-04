require 'minitest/autorun'
require 'tmpdir'
require 'digest'
require_relative '../sketchup_adapter/ruby_host/module_dependencies'

class ModuleDependenciesTest < Minitest::Test
  def setup
    @dir=Dir.mktmpdir
    @target=File.join(@dir,'target.rb');@dependency=File.join(@dir,'defaults.rb')
    File.write(@target,'original target');File.write(@dependency,'original defaults')
    @rules={'target.rb'=>{'sha256'=>Digest::SHA256.file(@target).hexdigest,
      'requires'=>{'defaults.rb'=>Digest::SHA256.file(@dependency).hexdigest}}}
  end
  def teardown;FileUtils.remove_entry(@dir);end
  def test_only_exact_original_target_and_dependency_match
    assert_equal [@dependency],SketchupAdapter::ModuleDependencies.prerequisites(@target,@rules)
    File.write(@target,'different release')
    assert_empty SketchupAdapter::ModuleDependencies.prerequisites(@target,@rules)
  end
  def test_changed_or_missing_dependency_is_not_silently_substituted
    File.write(@dependency,'unverified defaults')
    assert_raises(LoadError) { SketchupAdapter::ModuleDependencies.prerequisites(@target,@rules) }
    File.delete(@dependency)
    assert_raises(LoadError) { SketchupAdapter::ModuleDependencies.prerequisites(@target,@rules) }
  end
  def test_unrelated_module_is_unaffected
    assert_empty SketchupAdapter::ModuleDependencies.prerequisites(@dependency,@rules)
  end
end
