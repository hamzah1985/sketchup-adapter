# Smaller API pieces discovered while running the builder.
module Sketchup
  class EdgeUse
    attr_reader :edge, :loop
    def initialize(edge, loop, reversed, idx); @edge = edge; @loop = loop; @reversed = reversed; @idx = idx; end
    def reversed?; @reversed; end
    def face; @loop.face; end
    def partners; []; end
    def next; @loop.edgeuses[(@idx + 1) % @loop.edgeuses.length]; end
    def previous; @loop.edgeuses[@idx - 1]; end
    def start_vertex_normal; face.normal; end
    def end_vertex_normal; face.normal; end
  end

  class Loop
    def edgeuses
      vs = @verts
      ents = @face.parent_entities
      out = []
      vs.each_with_index do |v, i|
        w = vs[(i + 1) % vs.length]
        e = ents.edge_between(v, w)
        next unless e
        out << EdgeUse.new(e, self, !e.start.equal?(v), out.length)
      end
      out
    end
  end
end
