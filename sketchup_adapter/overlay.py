"""Project all Ruby preview points with one native camera matrix per frame."""
from __future__ import annotations

import numpy as np
from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QPen, QPolygonF


def paint(host, viewport, painter):
    items = host._overlay_primitives
    if not items:
        return
    templates = getattr(host, "_overlay_templates", {})
    expanded = []
    for item in items:
        if item.get("mode") == "instance":
            transform = np.eye(4,dtype=np.float64)
            if item.get("matrix") is not None:
                transform = np.asarray(item['matrix'],dtype=np.float64).reshape(4,4).T.copy()
                transform[:3,3] *= 0.0254
            else:
                transform[:3,3] = np.asarray(item.get('origin',(0,0,0)))*0.0254
            for local in templates.get(item.get("template"), []):
                if item.get('color') is not None:
                    local = dict(local,color=item['color'])
                expanded.append((local, transform))
        else:
            expanded.append((item, None))
    mvp = viewport.camera.projection_matrix() * viewport.camera.view_matrix()
    matrix = np.asarray(mvp.data(), dtype=np.float64).reshape(4,4).T
    width, height = viewport.width(), viewport.height()
    painter.save()
    try:
        for item, transform in expanded:
            color = QColor(*(item.get("color") or [30,130,210,255]))
            pen = QPen(color,max(1.0,float(item.get("width",1) or 1)))
            stipple = item.get("stipple")
            if stipple in ("-",".","dash","dot"):
                pen.setStyle(Qt.DashLine if stipple in ("-","dash") else Qt.DotLine)
            painter.setPen(pen)
            raw = item.get("points", [])
            if not raw:
                continue
            values = np.asarray(raw,dtype=np.float64)
            if item.get("space") == "screen":
                xy = values[:,:2]
            else:
                positions = np.ones((len(values),4),dtype=np.float64)
                # QVector3D stores float32; preserve the native boundary before
                # applying the camera's float32 matrix in a vectorized pass.
                positions[:,:3] = (values[:,:3]*0.0254).astype(np.float32)
                projected = matrix if transform is None else matrix @ transform
                clip = positions @ projected.T
                clip = clip[clip[:,3]>0]
                xy = np.empty((len(clip),2),dtype=np.float64)
                xy[:,0] = (clip[:,0]/clip[:,3]*0.5+0.5)*width
                xy[:,1] = (0.5-clip[:,1]/clip[:,3]*0.5)*height
            points = [QPointF(float(x),float(y)) for x,y in xy]
            mode = item.get("mode")
            if mode == "points":
                radius=max(1.0,float(item.get("point_size",6))/2)
                style=int(item.get('point_style',3))
                painter.setBrush(color if style in (2,7) else Qt.NoBrush)
                for point in points:
                    x,y=point.x(),point.y()
                    if style in (1,2):
                        painter.drawRect(QRectF(x-radius,y-radius,2*radius,2*radius))
                    elif style in (6,7):
                        painter.drawPolygon(QPolygonF([QPointF(x,y-radius),QPointF(x+radius,y+radius),QPointF(x-radius,y+radius)]))
                    else:
                        if style in (3,5):
                            painter.drawLine(QPointF(x-radius,y),QPointF(x+radius,y))
                            painter.drawLine(QPointF(x,y-radius),QPointF(x,y+radius))
                        if style in (4,5):
                            painter.drawLine(QPointF(x-radius,y-radius),QPointF(x+radius,y+radius))
                            painter.drawLine(QPointF(x-radius,y+radius),QPointF(x+radius,y-radius))
            elif mode in ("line_strip","line_loop") and len(points)>=2:
                poly=QPolygonF(points)
                if mode=="line_loop":poly.append(points[0])
                painter.drawPolyline(poly)
            elif mode in ("lines","line_pairs"):
                for i in range(0,len(points)-1,2):painter.drawLine(points[i],points[i+1])
            elif mode in ("triangles","quads","polygon"):
                n={"triangles":3,"quads":4,"polygon":len(points)}[mode]
                painter.setBrush(color)
                for i in range(0,len(points)-n+1,max(n,1)):
                    painter.drawPolygon(QPolygonF(points[i:i+n]))
            elif mode=="text" and points:
                offset = item.get("offset", (0, 0))
                painter.drawText(points[0] + QPointF(float(offset[0]), float(offset[1])),item.get("text",""))
    finally:
        painter.restore()
