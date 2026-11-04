require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
class DecimalLengthInputContracts < Minitest::Test
  def setup
    Host.reset_document
    @options=Sketchup.active_model.options['UnitsOptions']
    @options['LengthUnit']=2
  end
  def test_valid_legacy_decimal_inputs_keep_existing_inch_values
    values={'12'=>12.0/25.4, '12 mm'=>12.0/25.4, '12 cm'=>12.0/2.54,
      '12 m'=>12.0/0.0254, '12 in'=>12.0, %q{12"}=>12.0,
      '12 ft'=>144.0, %q{12'}=>144.0, '12 yd'=>432.0,
      '.5 in'=>0.5, '-.5 in'=>-0.5, '+1. in'=>1.0,
      %q{5' 5.5"}=>65.5, %q{5'-5.5"}=>65.5, %q{5' .5"}=>60.5,
      '  1.25 IN  '=>1.25}
    values.each { |text,expected| assert_in_delta expected,text.to_l,1e-8,text }
  end
  def test_parse_length_keeps_model_unit_behavior
    {0=>12.0,1=>144.0,2=>12.0/25.4,3=>12.0/2.54,4=>12.0/0.0254,5=>432.0}.each do |unit,expected|
      @options['LengthUnit']=unit
      assert_in_delta expected,Sketchup.parse_length('12'),1e-8,"LengthUnit=#{unit}"
    end
  end
  def test_malformed_decimals_raise_or_return_nil_instead_of_truncating
    ['1.2.3','.','+.','1..2mm','1.2.3 in','4.5.6ft',%q{5' ."},%q{5' 1.2.3"}].each do |text|
      assert_raises(ArgumentError,text) { text.to_l }
      assert_nil Sketchup.parse_length(text),text
    end
  end
end
