require 'minitest/autorun'
require 'tmpdir'
require 'digest'
require_relative '../sketchup_adapter/ruby_host/legacy_modules'

class LegacyModuleRoutesTest < Minitest::Test
  def setup
    @dir=Dir.mktmpdir
    @menu=File.join(@dir,'fixture-menu.rbs');File.write(@menu,'verified menu')
    @target=File.join(@dir,'variant.rbs');File.write(@target,'verified original variant')
    @profile={'menu'=>'fixture-menu.rbs','sha256'=>Digest::SHA256.file(@menu).hexdigest,
      'aliases'=>{'/obsolete'=>['/variant',Digest::SHA256.file(@target).hexdigest]}}
    SketchupAdapter::LegacyModules.prepare(@menu,@profile)
  end
  def teardown;FileUtils.remove_entry(@dir);end
  def route(root=@dir,name='/obsolete');SketchupAdapter::LegacyModules.route(root,name);end
  def test_verified_original_variant_and_unrelated_calls
    assert_equal '/variant',route
    assert_equal '/other',route(@dir,'/other')
    assert_equal '/obsolete',route(File.join(@dir,'other'))
  end
  def test_existing_legacy_file_takes_precedence
    File.write(File.join(@dir,'obsolete.rb'),'vendor supplied legacy implementation')
    assert_equal '/obsolete',route
  end
  def test_different_menu_or_variant_cannot_be_substituted
    File.write(@target,'different variant')
    assert_equal '/obsolete',route
    File.write(@target,'verified original variant');File.write(@menu,'different menu')
    assert_equal '/obsolete',route
  end
  def test_missing_variant_keeps_original_loader_error
    File.delete(@target)
    assert_equal '/obsolete',route
  end
end
