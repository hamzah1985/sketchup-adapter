require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
class PlaneFitTest < Minitest::Test
  def test_unordered_planar_points_have_a_valid_plane
    points=[[0,0,3],[2,2,3],[0,2,3],[2,0,3]]
    plane=Geom.fit_plane_to_points(points.map { |p| Geom::Point3d.new(p) })
    assert_in_delta 1.0,plane[2].abs,1e-10
    points.each { |p| assert_in_delta 0,Geom::Point3d.new(p).distance_to_plane(plane),1e-10 }
  end
  def test_nonplanar_samples_use_covariance_fit_not_polygon_winding
    points=[[0,0,0.02],[2,0,-0.02],[2,2,0.02],[0,2,-0.01],[0,2,-0.01]].map { |p| Geom::Point3d.new(p) }
    plane=Geom.fit_plane_to_points(points)
    assert_in_delta 1.0,plane[2].abs,1e-9
    assert_in_delta 0,plane[0],1e-9
    assert_in_delta 0,plane[1],1e-9
    assert_in_delta 0,plane[3],1e-9
  end
  def test_translation_and_input_order_do_not_change_the_fit
    points=[[0,0,0.02],[2,0,-0.02],[2,2,0.02],[0,2,-0.01],[0,2,-0.01]].map { |p| Geom::Point3d.new(p[0]+1000,p[1]-2000,p[2]+17) }
    plane=Geom.fit_plane_to_points(points.rotate(2))
    assert_in_delta 1,plane[2].abs,1e-8
    assert_in_delta 0,Geom::Point3d.new(1000,-2000,17).distance_to_plane(plane),1e-8
  end
end
