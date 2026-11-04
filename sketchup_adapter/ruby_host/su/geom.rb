# SketchUp Geom emulation for running Window Crafter outside SketchUp.
# Internal units are inches, like SketchUp.

class Length < Numeric
  Inches = 0; Feet = 1; Millimeter = 2; Centimeter = 3; Meter = 4; Yard = 5
  Decimal = 0; Architectural = 1; Engineering = 2; Fractional = 3
  SquareInches = 0; SquareFeet = 1; SquareMillimeter = 2; SquareCentimeter = 3; SquareMeter = 4; SquareYard = 5
  CubicInches = 0; CubicFeet = 1; CubicMillimeter = 2; CubicCentimeter = 3; CubicMeter = 4; CubicYard = 5
  Liter = 6; USGallon = 7
  def initialize(value); @value=Float(value); end
  def to_f; @value; end
  def to_i; @value.to_i; end
  alias to_int to_i
  def to_l; self; end
  def to_s; Sketchup.format_length(@value); end
  def inspect; @value.inspect; end
  def coerce(other); [Float(other),@value]; end
  def <=>(other); @value <=> other.to_f; end
  def ==(other); other.is_a?(Numeric) && @value==other.to_f; end
  def hash; @value.hash; end
  def eql?(other); other.is_a?(Length) && @value.eql?(other.to_f); end
  %i[+ - * / ** %].each { |operator| define_method(operator) { |other| @value.public_send(operator,other.to_f) } }
  def -@; -@value; end
  def +@; @value; end
  def abs; @value.abs; end
  def round(*args); @value.round(*args); end
  def finite?; @value.finite?; end
  def to_json(*args); @value.to_json(*args); end
end

class Numeric
  def mm; to_f / 25.4; end
  def cm; to_f / 2.54; end
  def m; to_f / 0.0254; end
  def km; to_f / 0.0000254; end
  def inch; to_f; end
  def feet; to_f * 12.0; end
  def yard; to_f * 36.0; end
  def to_mm; to_f * 25.4; end
  def to_cm; to_f * 2.54; end
  def to_m; to_f * 0.0254; end
  def to_km; to_f * 0.0000254; end
  def to_inch; to_f; end
  def to_feet; to_f / 12.0; end
  def to_yard; to_f / 36.0; end
  def to_l; Length.new(to_f); end
  def degrees; to_f * Math::PI / 180.0; end
  def radians; to_f * 180.0 / Math::PI; end
end

class String
  def to_l
    s = strip
    if s =~ /\A([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*(mm|cm|m|in|"|ft|'|yd)?\z/i
      v = $1.to_f
      case ($2 || "mm").downcase
      when "mm" then v.mm
      when "cm" then v.cm
      when "m" then v.m
      when "in", '"' then v
      when "ft", "'" then v * 12.0
      when "yd" then v * 36.0
      end
    elsif s =~ /\A(\d+)'\s*-?\s*((?:\d+(?:\.\d*)?|\.\d+))"?\z/
      $1.to_f * 12.0 + $2.to_f
    else
      raise ArgumentError, "Cannot convert \"#{self}\" to Length"
    end
  end
end

module Geom
  TOL = 0.001 # SketchUp's length tolerance, inches

  module VecOps
    def x; self[0].to_f; end
    def y; self[1].to_f; end
    def z; self[2].to_f; end
    def x=(v); self[0] = v.to_f; end
    def y=(v); self[1] = v.to_f; end
    def z=(v); self[2] = v.to_f; end
  end

  class Point3d
    include VecOps
    def initialize(*a)
      a = a.first.to_a if a.length == 1
      a = [0, 0, 0] if a.empty?
      @c = [a[0].to_f, a[1].to_f, (a[2] || 0).to_f]
    end
    def [](i); @c[i]; end
    def []=(i, v); @c[i] = v.to_f; end
    def to_a; @c.dup; end
    def clone; Point3d.new(@c); end
    alias dup clone
    def +(v); Point3d.new(x + v.x, y + v.y, z + v.z); end
    def -(o)
      o.is_a?(Vector3d) ? Point3d.new(x - o.x, y - o.y, z - o.z) : Vector3d.new(x - o.x, y - o.y, z - o.z)
    end
    def ==(o)
      return false unless o.respond_to?(:to_a) && o.to_a.length >= 3
      distance(o) <= TOL
    end
    def distance(o); Math.sqrt((x - o.x)**2 + (y - o.y)**2 + (z - o.z)**2); end
    def vector_to(o); Vector3d.new(o.x - x, o.y - y, o.z - z); end
    def offset(v, d = nil)
      v = Vector3d.new(v)
      v = v.normalize * d if d
      Point3d.new(x + v.x, y + v.y, z + v.z)
    end
    def offset!(v, d = nil); @c = offset(v, d).to_a; self; end
    def transform(t); Transformation.coerce(t).apply_point(self); end
    def transform!(t); @c = transform(t).to_a; self; end
    def set!(*a); a = a.first.to_a if a.length == 1; @c = [a[0].to_f, a[1].to_f, a[2].to_f]; self; end
    def project_to_plane(*parts)
      pl=parts.length==1 ? parts.first : parts
      pt, n = Geom.plane_parts(pl)
      d = (self - pt).dot(n)
      Point3d.new(x - n.x * d, y - n.y * d, z - n.z * d)
    end
    def distance_to_plane(pl)
      pt, n = Geom.plane_parts(pl)
      ((self - pt).dot(n)).abs
    end
    def on_plane?(pl); distance_to_plane(pl) <= TOL; end
    def project_to_line(*parts)
      line=parts.length==1 ? parts.first : parts
      pt, dir = Geom.line_parts(line)
      d = dir.normalize
      t = (self - pt).dot(d)
      pt + Vector3d.new(d.x * t, d.y * t, d.z * t)
    end
    def distance_to_line(line); distance(project_to_line(line)); end
    def on_line?(*parts); distance(project_to_line(*parts)) <= TOL; end
    def valid?; true; end
    def to_s; "Point3d(#{@c.map { |v| v.round(4) }.join(', ')})"; end
    alias inspect to_s
    def hash; @c.map { |v| (v / TOL).round }.hash; end
    def eql?(o); self == o; end
    def self.linear_combination(w1, p1, w2, p2)
      Point3d.new(p1.x * w1 + p2.x * w2, p1.y * w1 + p2.y * w2, p1.z * w1 + p2.z * w2)
    end
  end

  class Vector3d
    include VecOps
    def initialize(*a)
      a = a.first.to_a if a.length == 1
      a = [0, 0, 0] if a.empty?
      @c = [a[0].to_f, a[1].to_f, (a[2] || 0).to_f]
    end
    def [](i); @c[i]; end
    def []=(i, v); @c[i] = v.to_f; end
    def to_a; @c.dup; end
    def clone; Vector3d.new(@c); end
    alias dup clone
    def length; Math.sqrt(x * x + y * y + z * z); end
    def length=(l); n = normalize; @c = [n.x * l, n.y * l, n.z * l]; end
    def normalize; l = length; l < 1e-12 ? Vector3d.new(0, 0, 0) : Vector3d.new(x / l, y / l, z / l); end
    def normalize!; @c = normalize.to_a; self; end
    def reverse; Vector3d.new(-x, -y, -z); end
    def reverse!; @c = reverse.to_a; self; end
    def dot(v); x * v.x + y * v.y + z * v.z; end
    alias % dot
    def cross(v); Vector3d.new(y * v.z - z * v.y, z * v.x - x * v.z, x * v.y - y * v.x); end
    def *(o); o.is_a?(Numeric) ? Vector3d.new(x * o, y * o, z * o) : cross(o); end
    def +(v); Vector3d.new(x + v.x, y + v.y, z + v.z); end
    def -(v); Vector3d.new(x - v.x, y - v.y, z - v.z); end
    def -@; reverse; end
    def ==(o); o.respond_to?(:to_a) && (self - Vector3d.new(o.to_a)).length <= 1e-9; end
    def valid?; length > 1e-12; end
    def unitvector?; (length - 1.0).abs < 1e-9; end
    def parallel?(v); cross(Vector3d.new(v.to_a).normalize).length < 1e-9 * [1, length].max && valid?; end
    def samedirection?(v); parallel?(v) && dot(v) > 0; end
    def perpendicular?(v); dot(Vector3d.new(v.to_a).normalize).abs < 1e-9 * [1, length].max; end
    def angle_between(v)
      d = normalize.dot(Vector3d.new(v.to_a).normalize)
      Math.acos([[d, 1.0].min, -1.0].max)
    end
    def transform(t); Transformation.coerce(t).apply_vector(self); end
    def transform!(t); @c = transform(t).to_a; self; end
    def set!(*a); a = a.first.to_a if a.length == 1; @c = [a[0].to_f, a[1].to_f, a[2].to_f]; self; end
    def axes
      zv = normalize
      xv = (zv.z.abs < 0.9999 ? Vector3d.new(0, 0, 1) : Vector3d.new(0, 1, 0)).cross(zv)
      xv = if zv.parallel?([0, 0, 1]) then Vector3d.new(1, 0, 0) * (zv.z > 0 ? 1 : 1) else xv.normalize end
      yv = zv.cross(xv).normalize
      [xv, yv, zv]
    end
    def to_s; "Vector3d(#{@c.map { |v| v.round(4) }.join(', ')})"; end
    alias inspect to_s
    def self.linear_combination(*a)
      r = Vector3d.new(0, 0, 0)
      a.each_slice(2) { |w, v| r += Vector3d.new(v.to_a) * w }
      r
    end
  end

  def self.plane_parts(pl)
    if pl.length == 4 && pl.all? { |v| v.is_a?(Numeric) }
      n = Vector3d.new(pl[0], pl[1], pl[2])
      l = n.length
      n = n.normalize
      [Point3d.new(n.x * -pl[3] / l, n.y * -pl[3] / l, n.z * -pl[3] / l), n]
    else
      [Point3d.new(pl[0].to_a), Vector3d.new(pl[1].to_a).normalize]
    end
  end

  def self.line_parts(line)
    a = Point3d.new(line[0].to_a)
    b = line[1]
    dir = b.is_a?(Vector3d) ? b : (Point3d.new(b.to_a) - a)
    [a, dir]
  end

  def self.intersect_line_line(l1, l2)
    p1, d1 = line_parts(l1)
    p2, d2 = line_parts(l2)
    n = d1.cross(d2)
    return nil if n.length < 1e-12
    w = p2 - p1
    t = w.cross(d2).dot(n) / n.dot(n)
    s = w.cross(d1).dot(n) / n.dot(n)
    a = p1 + d1 * t
    b = p2 + d2 * s
    a.distance(b) <= TOL * 10 ? a : nil
  end

  def self.intersect_line_plane(line, pl)
    p, d = line_parts(line)
    pt, n = plane_parts(pl)
    den = d.dot(n)
    return nil if den.abs < 1e-12
    t = (pt - p).dot(n) / den
    p + d * t
  end

  def self.intersect_plane_plane(a, b)
    p1, n1 = plane_parts(a)
    p2, n2 = plane_parts(b)
    dir = n1.cross(n2)
    return nil if dir.length < 1e-12
    d1 = n1.dot(Vector3d.new(p1.to_a))
    d2 = n2.dot(Vector3d.new(p2.to_a))
    pt = (n2 * d1 - n1 * d2).cross(dir) * (1.0 / dir.dot(dir))
    [Point3d.new(pt.to_a), dir.normalize]
  end

  def self.fit_plane_to_points(*pts)
    pts = pts.flatten(1) if pts.length == 1
    pts = pts.map { |p| p=p.position if p.respond_to?(:position); Point3d.new(p.to_a) }
    n = newell(pts)
    c = centroid(pts)
    # Newell is an ordered-polygon normal, not a least-squares fit for an
    # unordered/nonplanar point cloud. Keep its fast exact planar result;
    # otherwise take the covariance matrix's smallest eigenvector.
    extent=pts.map { |p| p.distance(c) }.max.to_f
    if !n.valid? || pts.any? { |p| (p-c).dot(n).abs>[extent*1e-10,1e-10].max }
      covariance=Array.new(3) { Array.new(3,0.0) }
      pts.each do |point|
        delta=(point-c).to_a
        3.times { |i| 3.times { |j| covariance[i][j]+=delta[i]*delta[j] } }
      end
      vectors=Array.new(3) { |i| Array.new(3) { |j| i==j ? 1.0 : 0.0 } }
      32.times do
        p,q=[[0,1],[0,2],[1,2]].max_by { |i,j| covariance[i][j].abs }
        off=covariance[p][q]
        break if off.abs<=[covariance.each_with_index.map { |row,i| row[i].abs }.max.to_f*1e-15,1e-24].max
        tau=(covariance[q][q]-covariance[p][p])/(2.0*off)
        t=(tau<0 ? -1.0 : 1.0)/(tau.abs+Math.sqrt(1+tau*tau))
        cosine=1.0/Math.sqrt(1+t*t);sine=t*cosine
        covariance[p][p]-=t*off;covariance[q][q]+=t*off
        covariance[p][q]=covariance[q][p]=0.0
        3.times do |k|
          if k!=p && k!=q
            a,b=covariance[k][p],covariance[k][q]
            covariance[k][p]=covariance[p][k]=cosine*a-sine*b
            covariance[k][q]=covariance[q][k]=sine*a+cosine*b
          end
          a,b=vectors[k][p],vectors[k][q]
          vectors[k][p]=cosine*a-sine*b;vectors[k][q]=sine*a+cosine*b
        end
      end
      index=(0..2).min_by { |i| covariance[i][i] }
      fitted=Vector3d.new(vectors.map { |row| row[index] }).normalize
      fitted.reverse! if n.valid? && fitted.dot(n)<0
      n=fitted
    end
    [n.x, n.y, n.z, -n.dot(Vector3d.new(c.to_a))]
  end

  def self.newell(pts)
    nx = ny = nz = 0.0
    pts.each_with_index do |a, i|
      b = pts[(i + 1) % pts.length]
      nx += (a.y - b.y) * (a.z + b.z)
      ny += (a.z - b.z) * (a.x + b.x)
      nz += (a.x - b.x) * (a.y + b.y)
    end
    Vector3d.new(nx, ny, nz).normalize
  end

  def self.centroid(pts)
    s = [0.0, 0.0, 0.0]
    pts.each { |p| s[0] += p.x; s[1] += p.y; s[2] += p.z }
    Point3d.new(s.map { |v| v / pts.length })
  end

  def self.point_in_polygon_2D(pt, poly, border = false)
    inside = false
    n = poly.length
    j = n - 1
    n.times do |i|
      a = poly[i]; b = poly[j]
      if border
        seg = Point3d.new(b.x - a.x, b.y - a.y, 0)
        # on-edge check
        ab = Vector3d.new(b.x - a.x, b.y - a.y, 0)
        ap = Vector3d.new(pt.x - a.x, pt.y - a.y, 0)
        if ab.cross(ap).length <= TOL * [ab.length, 1].max && ap.dot(ab) >= -TOL && ap.length <= ab.length + TOL
          return true
        end
      end
      if ((a.y > pt.y) != (b.y > pt.y)) && (pt.x < (b.x - a.x) * (pt.y - a.y) / (b.y - a.y) + a.x)
        inside = !inside
      end
      j = i
    end
    inside
  end

  def self.linear_combination(w1, p1, w2, p2)
    Point3d.linear_combination(w1, p1, w2, p2)
  end

  class Transformation
    attr_reader :m # 16 floats, SketchUp column-major (to_a order)
    def xscale; xaxis.length; end
    def yscale; yaxis.length; end
    def zscale; zaxis.length; end

    def self.coerce(t)
      return t if t.is_a?(Transformation)
      Transformation.new(t)
    end

    def initialize(*a)
      @m = [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0].map(&:to_f)
      return if a.empty?
      if a.length == 1
        v = a.first
        if v.is_a?(Transformation)
          @m = v.m.dup
        elsif v.is_a?(Numeric)
          @m[0] = @m[5] = @m[10] = v.to_f
        elsif v.is_a?(Array) && v.length == 16
          @m = v.map(&:to_f)
        elsif v.is_a?(Vector3d) || v.is_a?(Point3d) || (v.is_a?(Array) && v.length == 3)
          @m[12], @m[13], @m[14] = v.to_a.map(&:to_f)
        else
          raise ArgumentError, "Transformation.new(#{v.inspect})"
        end
      elsif a.length == 2 # origin, zaxis
        o = Point3d.new(a[0].to_a)
        xv, yv, zv = Vector3d.new(a[1].to_a).axes
        set_axes(o, xv, yv, zv)
      elsif a.length == 3 # origin xaxis yaxis
        o = Point3d.new(a[0].to_a)
        xv = Vector3d.new(a[1].to_a).normalize
        yv = Vector3d.new(a[2].to_a).normalize
        set_axes(o, xv, yv, xv.cross(yv).normalize)
      end
    end

    def set_axes(o, xv, yv, zv)
      @m = [xv.x, xv.y, xv.z, 0.0, yv.x, yv.y, yv.z, 0.0, zv.x, zv.y, zv.z, 0.0, o.x, o.y, o.z, 1.0]
      self
    end

    def self.axes(o, xv, yv, zv = nil)
      xv = Vector3d.new(xv.to_a); yv = Vector3d.new(yv.to_a)
      zv = zv ? Vector3d.new(zv.to_a) : xv.cross(yv)
      new.set_axes(Point3d.new(o.to_a), xv.normalize, yv.normalize, zv.normalize)
    end

    def self.translation(v); new(Vector3d.new(v.to_a)); end

    def self.rotation(pt, axis, ang)
      pt = Point3d.new(pt.to_a)
      a = Vector3d.new(axis.to_a).normalize
      c = Math.cos(ang); s = Math.sin(ang); t = 1 - c
      x, y, z = a.x, a.y, a.z
      r = [t * x * x + c, t * x * y + s * z, t * x * z - s * y,
           t * x * y - s * z, t * y * y + c, t * y * z + s * x,
           t * x * z + s * y, t * y * z - s * x, t * z * z + c]
      tr = new
      tr.m[0], tr.m[1], tr.m[2] = r[0], r[1], r[2]
      tr.m[4], tr.m[5], tr.m[6] = r[3], r[4], r[5]
      tr.m[8], tr.m[9], tr.m[10] = r[6], r[7], r[8]
      translation(pt) * tr * translation(Vector3d.new(-pt.x, -pt.y, -pt.z))
    end

    def self.scaling(*a)
      pt = nil
      pt = Point3d.new(a.shift.to_a) if a.first.is_a?(Point3d) || (a.first.is_a?(Array) && a.length > 1)
      sx, sy, sz = a.length == 1 ? [a[0], a[0], a[0]] : a
      tr = new
      tr.m[0], tr.m[5], tr.m[10] = sx.to_f, sy.to_f, sz.to_f
      pt ? translation(pt) * tr * translation(Vector3d.new(-pt.x, -pt.y, -pt.z)) : tr
    end

    def self.interpolate(t1, t2, w)
      new(t1.m.each_with_index.map { |v, i| v * (1 - w) + t2.m[i] * w })
    end

    def to_a; @m.dup; end
    def clone; Transformation.new(@m.dup); end
    def origin; Point3d.new(@m[12], @m[13], @m[14]); end
    def xaxis; Vector3d.new(@m[0], @m[1], @m[2]); end
    def yaxis; Vector3d.new(@m[4], @m[5], @m[6]); end
    def zaxis; Vector3d.new(@m[8], @m[9], @m[10]); end
    def identity?; @m.each_with_index.all? { |v, i| (v - (i % 5 == 0 ? 1.0 : 0.0)).abs < 1e-12 }; end
    def set!(t); @m = Transformation.coerce(t).m.dup; self; end

    def *(o)
      case o
      when Transformation
        a = @m; b = o.m
        r = Array.new(16, 0.0)
        4.times do |c|
          4.times do |rw|
            s = 0.0
            4.times { |k| s += a[k * 4 + rw] * b[c * 4 + k] }
            r[c * 4 + rw] = s
          end
        end
        Transformation.new(r)
      when Vector3d then apply_vector(o)
      when Point3d then apply_point(o)
      when Array then o.length == 16 ? self * Transformation.new(o) : apply_point(Point3d.new(o)).to_a
      else raise ArgumentError, "Transformation * #{o.class}"
      end
    end

    def apply_point(p)
      a = @m
      w = a[3] * p.x + a[7] * p.y + a[11] * p.z + a[15]
      w = 1.0 if w.abs < 1e-15
      Point3d.new((a[0] * p.x + a[4] * p.y + a[8] * p.z + a[12]) / w,
                  (a[1] * p.x + a[5] * p.y + a[9] * p.z + a[13]) / w,
                  (a[2] * p.x + a[6] * p.y + a[10] * p.z + a[14]) / w)
    end

    def apply_vector(v)
      a = @m
      Vector3d.new(a[0] * v.x + a[4] * v.y + a[8] * v.z,
                   a[1] * v.x + a[5] * v.y + a[9] * v.z,
                   a[2] * v.x + a[6] * v.y + a[10] * v.z)
    end

    def inverse
      m = @m
      inv = Array.new(16)
      inv[0] = m[5]*m[10]*m[15]-m[5]*m[11]*m[14]-m[9]*m[6]*m[15]+m[9]*m[7]*m[14]+m[13]*m[6]*m[11]-m[13]*m[7]*m[10]
      inv[4] = -m[4]*m[10]*m[15]+m[4]*m[11]*m[14]+m[8]*m[6]*m[15]-m[8]*m[7]*m[14]-m[12]*m[6]*m[11]+m[12]*m[7]*m[10]
      inv[8] = m[4]*m[9]*m[15]-m[4]*m[11]*m[13]-m[8]*m[5]*m[15]+m[8]*m[7]*m[13]+m[12]*m[5]*m[11]-m[12]*m[7]*m[9]
      inv[12] = -m[4]*m[9]*m[14]+m[4]*m[10]*m[13]+m[8]*m[5]*m[14]-m[8]*m[6]*m[13]-m[12]*m[5]*m[10]+m[12]*m[6]*m[9]
      inv[1] = -m[1]*m[10]*m[15]+m[1]*m[11]*m[14]+m[9]*m[2]*m[15]-m[9]*m[3]*m[14]-m[13]*m[2]*m[11]+m[13]*m[3]*m[10]
      inv[5] = m[0]*m[10]*m[15]-m[0]*m[11]*m[14]-m[8]*m[2]*m[15]+m[8]*m[3]*m[14]+m[12]*m[2]*m[11]-m[12]*m[3]*m[10]
      inv[9] = -m[0]*m[9]*m[15]+m[0]*m[11]*m[13]+m[8]*m[1]*m[15]-m[8]*m[3]*m[13]-m[12]*m[1]*m[11]+m[12]*m[3]*m[9]
      inv[13] = m[0]*m[9]*m[14]-m[0]*m[10]*m[13]-m[8]*m[1]*m[14]+m[8]*m[2]*m[13]+m[12]*m[1]*m[10]-m[12]*m[2]*m[9]
      inv[2] = m[1]*m[6]*m[15]-m[1]*m[7]*m[14]-m[5]*m[2]*m[15]+m[5]*m[3]*m[14]+m[13]*m[2]*m[7]-m[13]*m[3]*m[6]
      inv[6] = -m[0]*m[6]*m[15]+m[0]*m[7]*m[14]+m[4]*m[2]*m[15]-m[4]*m[3]*m[14]-m[12]*m[2]*m[7]+m[12]*m[3]*m[6]
      inv[10] = m[0]*m[5]*m[15]-m[0]*m[7]*m[13]-m[4]*m[1]*m[15]+m[4]*m[3]*m[13]+m[12]*m[1]*m[7]-m[12]*m[3]*m[5]
      inv[14] = -m[0]*m[5]*m[14]+m[0]*m[6]*m[13]+m[4]*m[1]*m[14]-m[4]*m[2]*m[13]-m[12]*m[1]*m[6]+m[12]*m[2]*m[5]
      inv[3] = -m[1]*m[6]*m[11]+m[1]*m[7]*m[10]+m[5]*m[2]*m[11]-m[5]*m[3]*m[10]-m[9]*m[2]*m[7]+m[9]*m[3]*m[6]
      inv[7] = m[0]*m[6]*m[11]-m[0]*m[7]*m[10]-m[4]*m[2]*m[11]+m[4]*m[3]*m[10]+m[8]*m[2]*m[7]-m[8]*m[3]*m[6]
      inv[11] = -m[0]*m[5]*m[11]+m[0]*m[7]*m[9]+m[4]*m[1]*m[11]-m[4]*m[3]*m[9]-m[8]*m[1]*m[7]+m[8]*m[3]*m[5]
      inv[15] = m[0]*m[5]*m[10]-m[0]*m[6]*m[9]-m[4]*m[1]*m[10]+m[4]*m[2]*m[9]+m[8]*m[1]*m[6]-m[8]*m[2]*m[5]
      det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12]
      raise "Singular transformation" if det.abs < 1e-18
      Transformation.new(inv.map { |v| v / det })
    end
    def invert!; @m = inverse.m; self; end
    def to_s; "Transformation(#{@m.map { |v| v.round(4) }.inspect})"; end
    alias inspect to_s
  end

  class BoundingBox
    def initialize; @min = nil; @max = nil; end
    def add(*pts)
      pts.flatten.each do |p|
        next if p.nil?
        if p.is_a?(BoundingBox)
          next if p.empty?
          add(p.min, p.max)
          next
        end
        p = Point3d.new(p.to_a)
        if @min
          @min = Point3d.new([@min.x, p.x].min, [@min.y, p.y].min, [@min.z, p.z].min)
          @max = Point3d.new([@max.x, p.x].max, [@max.y, p.y].max, [@max.z, p.z].max)
        else
          @min = p.clone; @max = p.clone
        end
      end
      self
    end
    def empty?; @min.nil?; end
    def valid?; !empty?; end
    def clear; @min = @max = nil; self; end
    def min; @min || Point3d.new(0, 0, 0); end
    def max; @max || Point3d.new(0, 0, 0); end
    def width; empty? ? 0.0 : @max.x - @min.x; end
    def height; empty? ? 0.0 : @max.y - @min.y; end
    def depth; empty? ? 0.0 : @max.z - @min.z; end
    def center; empty? ? Point3d.new(0, 0, 0) : Point3d.new((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2); end
    def diagonal; empty? ? 0.0 : min.distance(max); end
    def corner(i)
      Point3d.new(i & 1 == 0 ? min.x : max.x, i & 2 == 0 ? min.y : max.y, i & 4 == 0 ? min.z : max.z)
    end
    def contains?(p)
      p = p.is_a?(BoundingBox) ? p : Point3d.new(p.to_a)
      return contains?(p.min) && contains?(p.max) if p.is_a?(BoundingBox)
      !empty? && p.x >= min.x - TOL && p.x <= max.x + TOL && p.y >= min.y - TOL && p.y <= max.y + TOL && p.z >= min.z - TOL && p.z <= max.z + TOL
    end
    def intersect(b)
      r = BoundingBox.new
      return r if empty? || b.empty?
      lo = Point3d.new([min.x, b.min.x].max, [min.y, b.min.y].max, [min.z, b.min.z].max)
      hi = Point3d.new([max.x, b.max.x].min, [max.y, b.max.y].min, [max.z, b.max.z].min)
      r.add(lo, hi) if lo.x <= hi.x && lo.y <= hi.y && lo.z <= hi.z
      r
    end
  end

  class PolygonMesh
    AUTO_SOFTEN = 4; HIDE_BASED_ON_INDEX = 8; NO_SMOOTH_OR_HIDE = 0; SMOOTH_SOFT_EDGES = 1; SOFTEN_BASED_ON_INDEX = 2
    MESH_NORMALS = 4; MESH_UVQ_FRONT = 1; MESH_UVQ_BACK = 2; MESH_POINTS = 0
    attr_reader :points, :polys, :uvs_front, :uvs_back, :normals_list
    def initialize(*_a); @points = []; @polys = []; @uvs_front = []; @uvs_back = []; @normals_list = []; end
    def add_point(p)
      index=point_index(p)
      return index unless index.zero?
      @points << Point3d.new(p.to_a)
      @points.length
    end
    def point_index(p); i = @points.index { |q| q == p }; i ? i + 1 : 0; end
    def add_polygon(*pts)
      # The array form may contain point indices, not just Point3d objects.
      # Treating [1,2,3] as one point silently dropped every indexed triangle.
      pts = pts.first if pts.length == 1 && pts.first.is_a?(Array)
      idx = pts.map { |p| p.is_a?(Integer) ? p : (point_index(p).nonzero? || add_point(p)) }
      @polys << idx
      @polys.length
    end
    def count_points; @points.length; end
    def count_polygons; @polys.length; end
    def points; @points; end
    def point_at(i); @points[i.abs - 1]; end
    def polygon_at(i); @polys[i - 1]; end
    def polygons; @polys; end
    def polygon_points_at(i); @polys[i - 1].map { |k| point_at(k) }; end
    def normal_at(i); @normals_list[i - 1] || Vector3d.new(0, 0, 1); end
    def uv_at(i, front = true); (front ? @uvs_front : @uvs_back)[i - 1] || Point3d.new(0, 0, 1); end
    def set_uv(i, uv, front = true)
      (front ? @uvs_front : @uvs_back)[i.abs - 1] = Point3d.new(uv.to_a)
      nil
    end
    def uvs(front = true); front ? @uvs_front : @uvs_back; end
    def transform!(t); @points.map! { |p| p.transform(t) }; self; end
    def set_point(i, p); @points[i - 1] = Point3d.new(p.to_a); end
  end

  class LatLong; def initialize(*a); @a = a; end; end
  class UTM; end
end

X_AXIS = Geom::Vector3d.new(1, 0, 0)
Y_AXIS = Geom::Vector3d.new(0, 1, 0)
Z_AXIS = Geom::Vector3d.new(0, 0, 1)
ORIGIN = Geom::Point3d.new(0, 0, 0)
IDENTITY = Geom::Transformation.new

# SketchUp lets 3-element arrays stand in for points and vectors.
class Array
  include Geom::VecOps
  def to_point3d; Geom::Point3d.new(self); end
  def distance(o); Geom::Point3d.new(self).distance(o); end
  def transform(t); r = Geom::Point3d.new(self).transform(t).to_a; r; end
  def transform!(t); replace(transform(t)); end
  def offset(v, d = nil); Geom::Point3d.new(self).offset(v, d).to_a; end
  def dot(v); Geom::Vector3d.new(self).dot(v); end
  def cross(v); Geom::Vector3d.new(self).cross(v).to_a; end
  def normalize; Geom::Vector3d.new(self).normalize.to_a; end
  def vector_to(o); Geom::Point3d.new(self).vector_to(o); end
  def project_to_plane(pl); Geom::Point3d.new(self).project_to_plane(pl).to_a; end
  def on_plane?(pl); Geom::Point3d.new(self).on_plane?(pl); end
  def distance_to_plane(pl); Geom::Point3d.new(self).distance_to_plane(pl); end
end
