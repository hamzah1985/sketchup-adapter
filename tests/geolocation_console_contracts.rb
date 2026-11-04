require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  class << self
    attr_accessor :qa_calls,:qa_messages,:qa_location
    def notify(op,data={});(@qa_messages ||= []) << [op,data];end
    def call(name,data={})
      (@qa_calls ||= []) << [name,data]
      return true if name=='console_visible'
      return nil unless name=='geolocation'
      return {'ok'=>true,'georeferenced'=>!!@qa_location} if data['action']=='status'
      return {'ok'=>false,'error'=>'Set a geographic location for this model'} unless @qa_location
      case data['action']
      when 'to_local' then {'ok'=>true,'values'=>[25.4,50.8,76.2]}
      when 'to_geodetic' then {'ok'=>true,'values'=>[-105.0,40.0,1655.0]}
      end
    end
  end
end
class GeolocationConsoleContracts < Minitest::Test
  def setup
    Bridge.qa_calls=[];Bridge.qa_messages=[];Bridge.qa_location=true
    @model=Sketchup.active_model
  end
  def test_geographic_order_altitude_and_model_inches
    point=@model.latlong_to_point([-105,40,1655])
    assert_equal ['geolocation',{'action'=>'to_local','values'=>[-105.0,40.0,1655.0]}],Bridge.qa_calls.last
    [1000,2000,3000].zip(point.to_a) { |expected,actual| assert_in_delta expected,actual,1e-8 }
    latlong=@model.point_to_latlong(point)
    assert_equal [-105.0,40.0,1655.0],latlong.to_a
    Bridge.qa_calls.last[1]['values'].zip([25.4,50.8,76.2]) { |actual,expected| assert_in_delta expected,actual,1e-8 }
    assert @model.georeferenced?
  end
  def test_unlocated_model_fails_explicitly_without_fabricated_coordinates
    Bridge.qa_location=false
    refute @model.georeferenced?
    error=assert_raises(RuntimeError) { @model.latlong_to_point([-105,40]) }
    assert_match(/Set a geographic location/,error.message)
    assert_raises(ArgumentError) { @model.latlong_to_point([40]) }
  end
  def test_console_methods_reach_the_frontend
    assert SKETCHUP_CONSOLE.show
    assert SKETCHUP_CONSOLE.visible?
    assert_equal 3,SKETCHUP_CONSOLE.write('abc')
    assert SKETCHUP_CONSOLE.clear
    assert SKETCHUP_CONSOLE.hide
    assert_equal %w[console_action console_text console_action console_action],Bridge.qa_messages.map(&:first)
    assert_equal %w[show clear hide],Bridge.qa_messages.filter_map { |op,data| data['action'] if op=='console_action' }
  end
end
