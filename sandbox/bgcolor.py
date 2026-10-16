# Writes an XFCE solid-colour desktop config: bgcolor.py "#rrggbb" OUT.xml
import sys
hexc, out = sys.argv[1], sys.argv[2]
r, g, b = (int(hexc[i:i + 2], 16) / 255 for i in (1, 3, 5))
rgba = ('<value type="double" value="%.4f"/><value type="double" value="%.4f"/>'
        '<value type="double" value="%.4f"/><value type="double" value="1"/>' % (r, g, b))
props = []
for mon in ("monitor0", "monitorscreen", "monitorVNC-0"):
    ws = []
    for w in range(4):
        ws.append('<property name="workspace%d" type="empty">'
                  '<property name="color-style" type="int" value="0"/>'
                  '<property name="image-style" type="int" value="0"/>'
                  '<property name="rgba1" type="array">%s</property>'
                  '<property name="last-image" type="string" value=""/>'
                  '</property>' % (w, rgba))
    props.append('<property name="%s" type="empty">%s</property>' % (mon, "".join(ws)))
xml = ('<?xml version="1.0" encoding="UTF-8"?>\n<channel name="xfce4-desktop" version="1.0">'
       '<property name="backdrop" type="empty"><property name="screen0" type="empty">'
       + "".join(props) + '</property></property></channel>\n')
open(out, "w").write(xml)
