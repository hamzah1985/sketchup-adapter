# Indexed asset edges already have authored topology. Import them through the
# mesh primitive instead of the interactive line tool's face intersection scan.
module Host
  module CompactFaucetImport
    def add_mesh(entities, points, faces, loose_edges, target_x, target_y, deck_z)
      ax, ay, az = Essentials::CompactFaucet::BASE_ANCHOR_MM
      transformed = points.map do |x, y, z|
        Essentials::U.pt(target_x + x - ax, target_y + y - ay, deck_z + z - az)
      end
      mesh = Geom::PolygonMesh.new(transformed.length, faces.length)
      transformed.each { |point| mesh.add_point(point) }
      faces.each { |indices| mesh.add_polygon(indices) }
      entities.add_faces_from_mesh(mesh, 0)
      loose_edges.each do |a, b|
        edge = entities.edge(entities.vertex(transformed[a]), entities.vertex(transformed[b]))
        next unless edge && edge.valid?
        edge.soft = false
        edge.smooth = false
        edge.hidden = false
      end
      entities
    end
  end
end
