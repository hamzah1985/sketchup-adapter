# Expose the accepted draft point to IngeTrazo's existing snap engine. The
# upstream tool keeps ownership of its draft, arrow planes and Shift slope.
module Host
  module FenceInference
    def bridge_inference_state
      points = @draft.points
      enabled = active? && !@finished && !@draft.closed
      anchor = enabled ? points.last : nil
      direction = nil
      if anchor && @shift_lock && @shift_input && @shift_input.valid?
        delta = @shift_input.position - Geom::Point3d.new(anchor)
        direction = delta.normalize.to_a if delta.length > 1e-8
      end
      {'start'=>anchor, 'first'=>enabled ? points.first : nil,
       'cursor'=>enabled ? @cursor : nil, 'plane'=>@plane_heading,
       'plane_label'=>@plane_label, 'shift_direction'=>direction}
    end

    def bridge_inference_items
      state = bridge_inference_state
      a, b = state['start'], state['cursor']
      return [] unless a && b
      color, text = nil, nil
      if state['shift_direction']
        color, text = [180, 40, 190, 255], 'Shift locked'
      elsif @plane_heading
        color = @plane_label == 'Red' ? [215, 55, 45, 255] :
                (@plane_label == 'Green' ? [35, 155, 70, 255] : [180, 40, 190, 255])
        text = "#{@plane_label} direction; free rise"
      else
        delta = a.zip(b).map { |x,y| (y-x).abs }
        axis = delta.each_index.max_by { |i| delta[i] }
        if delta[axis] > 1e-6 && delta.each_index.all? { |i| i == axis || delta[i] < delta[axis] * 1e-5 }
          color = [[215,55,45,255],[35,155,70,255],[45,90,220,255]][axis]
          text = "On #{%w[Red Green Blue][axis]} axis; hold Shift to lock"
        end
      end
      return [] unless color
      [{'mode'=>'lines','space'=>'world','points'=>[a,b],'color'=>color,'width'=>3},
       {'mode'=>'points','space'=>'world','points'=>[b],'color'=>color,'point_size'=>8},
       {'mode'=>'text','space'=>'world','points'=>[b],'color'=>color,'text'=>text,'offset'=>[12,-10]}]
    end
  end
end
