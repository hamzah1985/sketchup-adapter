require 'minitest/autorun'
require 'tempfile'
require_relative '../sketchup_adapter/ruby_host/host'

module Bridge
  def self.notify(*); end
  def self.call(*); raise 'Unexpected host service'; end
end

class DrawingMaterialContracts < Minitest::Test
  def setup
    Sketchup.reset_model!
    @model = Sketchup.active_model
    @face = @model.entities.add_face([[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]])
    @edge = @face.edges.first
    @group = @model.entities.add_group
  end

  def test_names_resolve_to_the_existing_material_on_faces_groups_and_edges
    material = @model.materials.add('Roof tile')
    material.color = [23, 42, 71]
    material.alpha = 0.6
    Tempfile.create(['adapter-texture', '.png']) do |image|
      image.binmode
      image.write([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1].pack('C*'))
      image.flush
      material.texture = [image.path, 4, 8]
      [@face, @edge, @group].each do |entity|
        entity.material = 'Roof tile'
        assert_same material, entity.material
        assert_equal image.path, entity.material.texture.filename
        assert_in_delta 0.6, entity.material.alpha
      end
      @face.back_material = 'Roof tile'
      assert_same material, @face.back_material
      assert_equal [4.0, 8.0], [@face.back_material.texture.width, @face.back_material.texture.height]
    end
  end

  def test_front_and_back_independently_accept_materials_colors_and_nil
    back = @model.materials.add('back')
    @face.material = [255, 0, 0, 128]
    @face.back_material = back
    assert_instance_of Sketchup::Material, @face.material
    assert_equal [255, 0, 0, 128], @face.material.color.to_a
    assert_in_delta 128.0 / 255, @face.material.alpha
    assert_same back, @face.back_material
    @face.material = nil
    assert_nil @face.material
    assert_same back, @face.back_material
    @face.back_material = nil
    assert_nil @face.back_material
    @face.material = 'red'
    assert_equal [255, 0, 0], @face.material.color.to_a.first(3)
    @face.back_material = Sketchup::Color.new(1, 2, 3)
    assert_equal [1, 2, 3], @face.back_material.color.to_a.first(3)
  end

  def test_invalid_values_fail_without_replacing_existing_material
    material = @model.materials.add('valid')
    @face.material = material
    assert_raises(ArgumentError) { @face.material = 'unknown material name' }
    assert_raises(TypeError) { @face.material = Object.new }
    assert_same material, @face.material
  end

  def test_color_swatch_does_not_mutate_a_user_material_with_the_same_name
    original = @model.materials.add('[Color 255,0,0,255]')
    original.color = [1, 2, 3]
    @face.material = 'red'
    refute_same original, @face.material
    assert_equal [1, 2, 3], original.color.to_a.first(3)
    assert_equal [255, 0, 0], @face.material.color.to_a.first(3)
  end
end
