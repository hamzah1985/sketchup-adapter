require 'minitest/autorun'
require_relative '../sketchup_adapter/ruby_host/host'
module Bridge
  def self.notify(*);end
end
class OperationContractsTest < Minitest::Test
  def setup;Sketchup.reset_model!;@model=Sketchup.active_model;end
  def finish(&block);SketchupAdapter::OperationContracts.finish_new_operation(@model,&block);end
  def face;@model.entities.add_face([[0,0,0],[2,0,0],[2,2,0],[0,2,0]]);end
  def test_successful_builder_commits_its_new_operation_once
    result=finish { @model.start_operation('complete callback');face;:original_result }
    assert_equal :original_result,result
    assert_equal 0,@model.operation_depth
    assert_equal 1,@model.committed_revision
    assert_equal 1,@model.entities.faces.length
  end
  def test_failure_keeps_operation_abortable_and_removes_partial_geometry
    assert_raises(RuntimeError) { finish { @model.start_operation('failed callback');face;raise 'fault' } }
    assert_equal 1,@model.operation_depth
    @model.abort_operation
    assert_empty @model.entities.faces
  end
  def test_callers_existing_operation_is_not_committed
    @model.start_operation('caller preview')
    token=@model.bridge_operation_token
    finish { face }
    assert_same token,@model.bridge_operation_token
    assert_equal 0,@model.committed_revision
    @model.abort_operation
    assert_empty @model.entities.faces
  end
  def test_unverified_callback_is_not_accepted
    klass=Class.new { def create_geometry;end }
    refute SketchupAdapter::OperationContracts.verified?(klass)
  end
end
