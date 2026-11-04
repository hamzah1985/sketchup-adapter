# Cursor and selection edges refer to editable model entities, not detached hits.
module Host
  class << self
    def import_native_edges(records)
      @host_edge_records ||= {}
      entities=Sketchup.active_model.entities
      Array(records).each do |data|
        next unless data['kind']=='edge'
        previous=@host_edge_records[data['token']]
        next if previous && previous[:edge].valid?
        points=%w[a b].map { |key| Geom::Point3d.new(data[key].map { |v| v/INCH }) }
        edge=entities.add_line(*points)
        next unless edge
        edge.soft=!!data['soft'];edge.hidden=!!data['hidden']
        edge.layer=data['layer'] if data['layer'] && Sketchup.active_model.layers[data['layer']]
        edge.instance_variable_set(:@adapter_edge_token,data['token'])
        @host_edges << edge unless @host_edges.include?(edge)
        reversed=edge.start.position.distance(points[0])>1e-7
        @host_edge_records[data['token']]={edge:edge,source:data,reversed:reversed,baseline:native_edge_data(edge,reversed)}
      end
    end

    def native_edge(token)
      record=(@host_edge_records || {})[token]
      record && record[:edge].valid? ? record[:edge] : nil
    end

    def native_edge_data(edge,reversed=false)
      return nil unless edge.valid?
      points=edge.vertices.map { |v| m(v.position) };points.reverse! if reversed
      {'points'=>points,'soft'=>edge.soft?,'hidden'=>edge.hidden?,
       'layer'=>edge.layer && edge.layer.name}
    end

    def sync_native_edges
      (@host_edge_records || {}).each do |token,record|
        current=native_edge_data(record[:edge],record[:reversed])
        next if current==record[:baseline]
        record[:baseline]=current
        Bridge.notify('edge_patch',{'token'=>token,'points'=>nil,'surface_boundary'=>!!record[:surface_boundary]}.merge(current || {}))
      end
    end

    def restore_native_edges
      missing=(@host_edge_records || {}).values.select { |record| !record[:edge].valid? && record[:baseline] }
      missing.each { |record| @host_edge_records.delete(record[:source]['token']) }
      Sketchup.silence_bridge_events { import_native_edges(missing.map { |record| record[:source] }) } unless missing.empty?
    end
  end
end
