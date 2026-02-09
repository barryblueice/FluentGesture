import sys
import json
import ctypes
import numpy as np
from ctypes import wintypes
from PySide6.QtWidgets import QApplication, QMainWindow, QInputDialog
from PySide6.QtCore import Qt, Signal, QPointF, QTimer
from PySide6.QtGui import QPainter, QColor, QPen, QImage
from scipy.optimize import linear_sum_assignment

def frechet_distance(P, Q):
    """计算离散弗雷歇距离 (Discrete Fréchet Distance)"""
    n, m = len(P), len(Q)
    if n == 0 or m == 0: return float('inf')
    ca = np.ones((n, m)) * -1

    def calculate(i, j):
        if ca[i, j] > -1: return ca[i, j]
        dist = np.linalg.norm(np.array(P[i]) - np.array(Q[j]))
        if i == 0 and j == 0: ca[i, j] = dist
        elif i > 0 and j == 0: ca[i, j] = max(calculate(i-1, 0), dist)
        elif i == 0 and j > 0: ca[i, j] = max(calculate(0, j-1), dist)
        elif i > 0 and j > 0: ca[i, j] = max(min(calculate(i-1, j), 
                                                calculate(i-1, j-1), 
                                                calculate(i, j-1)), dist)
        else: ca[i, j] = float("inf")
        return ca[i, j]

    import sys
    sys.setrecursionlimit(2000)
    return calculate(n-1, m-1)

def resample_points(points, num_points=30):
    if len(points) < 2: return points
    pts = np.array(points)
    dist = np.sqrt(np.sum(np.diff(pts, axis=0)**2, axis=1))
    cumulative_dist = np.insert(np.cumsum(dist), 0, 0)
    total_length = cumulative_dist[-1]
    if total_length == 0: return [points[0]] * num_points
    
    interp_dist = np.linspace(0, total_length, num_points)
    resampled_x = np.interp(interp_dist, cumulative_dist, pts[:, 0])
    resampled_y = np.interp(interp_dist, cumulative_dist, pts[:, 1])
    return np.vstack((resampled_x, resampled_y)).T.tolist()

def normalize_stroke(points):
    if not points: return []
    pts = np.array(points)
    min_coords = pts.min(axis=0)
    pts = pts - min_coords
    max_dims = pts.max(axis=0)
    scale = max(max_dims[0], max_dims[1])
    if scale > 0:
        pts = (pts / scale) * 100
    final_max = pts.max(axis=0)
    offset = (100 - final_max) / 2
    pts = pts + offset
    return pts.tolist()


WM_INPUT = 0x00FF
RID_INPUT = 0x10000003

class RAWINPUTHEADER(ctypes.Structure):
    _fields_ = [("dwType", wintypes.DWORD), ("dwSize", wintypes.DWORD),
                ("hDevice", wintypes.HANDLE), ("wParam", wintypes.WPARAM)]

class RAWINPUTDEVICE(ctypes.Structure):
    _fields_ = [("usUsagePage", wintypes.USHORT), ("usUsage", wintypes.USHORT),
                ("dwFlags", wintypes.DWORD), ("hwndTarget", wintypes.HWND)]

def parse_touchpad_payload(payload):
    points = []
    if len(payload) < 30: return points
    offsets = [9, 14, 19, 24, 29] # PTP 协议中典型的 5 指偏移
    for offset in offsets:
        if offset + 4 >= len(payload): continue
        status = payload[offset]
        x = payload[offset + 1] | (payload[offset + 2] << 8)
        y = payload[offset + 3] | (payload[offset + 4] << 8)
        if status != 0 and (x > 0 or y > 0):
            points.append((x, y))
    return points


class Track:
    def __init__(self, pt, color):
        self.last_pt = pt
        self.smoothed_pt = pt
        self.color = color
        self.points = [(pt.x(), pt.y())]
        self.miss = 0
        self.alpha = 0.4

    def update(self, pt):
        self.smoothed_pt = QPointF(
            self.alpha * pt.x() + (1 - self.alpha) * self.smoothed_pt.x(),
            self.alpha * pt.y() + (1 - self.alpha) * self.smoothed_pt.y(),
        )
        self.last_pt = pt
        self.points.append((self.smoothed_pt.x(), self.smoothed_pt.y()))
        self.miss = 0

class GestureDrawingWindow(QMainWindow):
    raw_touch_data_signal = Signal(list)

    def __init__(self):
        super().__init__()
        self.setWindowTitle("触摸板手势录制识别引擎 (R:录制 Space:清除)")
        self.setGeometry(100, 100, 1000, 700)

        self.gesture_file = "gestures_db.json"
        self.gesture_library = self.load_library()
        
        self.is_recording = False
        self.record_name = ""

        self.register_touchpad()
        self.canvas = QImage(self.size(), QImage.Format_ARGB32)
        self.canvas.fill(Qt.white)
        
        self.tracks = []
        self.new_points_queue = []
        self.raw_touch_data_signal.connect(self.process_raw_points)

        self.timer = QTimer()
        self.timer.timeout.connect(self.refresh_ui)
        self.timer.start(16)

    def load_library(self):
        try:
            with open(self.gesture_file, 'r') as f:
                return json.load(f)
        except: return {}

    def save_library(self):
        with open(self.gesture_file, 'w') as f:
            json.dump(self.gesture_library, f)

    def register_touchpad(self):
        rid = RAWINPUTDEVICE(0x0D, 0x05, 0x00000100, self.winId())
        ctypes.windll.user32.RegisterRawInputDevices(ctypes.byref(rid), 1, ctypes.sizeof(rid))

    def keyPressEvent(self, event):
        if event.key() == Qt.Key_R:
            name, ok = QInputDialog.getText(self, "录制手势", "输入名称 (如 Circle):")
            if ok and name:
                self.record_name = name
                self.is_recording = True
                self.canvas.fill(QColor("#fff9c4"))
                self.update()
        elif event.key() == Qt.Key_Space:
            self.canvas.fill(Qt.white)
            self.update()

    def process_raw_points(self, points):
        self.new_points_queue.append(points)

    def refresh_ui(self):
        if not self.new_points_queue and not self.tracks: return
        
        points_to_draw = [pt for batch in self.new_points_queue for pt in batch]
        self.new_points_queue.clear()

        painter = QPainter(self.canvas)
        painter.setRenderHint(QPainter.Antialiasing)

        new_pts = [QPointF((x / 3500.0) * self.width(), (y / 2500.0) * self.height()) for x, y in points_to_draw]
        used_tracks = set()

        if self.tracks and new_pts:
            cost = np.zeros((len(self.tracks), len(new_pts)))
            for i, t in enumerate(self.tracks):
                for j, p in enumerate(new_pts):
                    cost[i, j] = (t.last_pt - p).manhattanLength()
            rows, cols = linear_sum_assignment(cost)
            for r, c in zip(rows, cols):
                if cost[r, c] < 80:
                    track = self.tracks[r]
                    track.update(new_pts[c])
                    painter.setPen(QPen(track.color, 4, Qt.SolidLine, Qt.RoundCap))
                    painter.drawLine(QPointF(*track.points[-2]), QPointF(*track.points[-1]))
                    used_tracks.add(track)

        for pt in new_pts:
            if not any((t.last_pt - pt).manhattanLength() < 80 for t in used_tracks):
                self.tracks.append(Track(pt, QColor("#2ecc71")))

        for track in list(self.tracks):
            if track not in used_tracks:
                track.miss += 1
                if track.miss >= 5: # 手指离开
                    self.handle_stroke_done(track)
                    self.tracks.remove(track)
        
        painter.end()
        self.update()

    def handle_stroke_done(self, track):
        if len(track.points) < 10: return
        
        processed = normalize_stroke(resample_points(track.points, 30))

        if self.is_recording:
            self.gesture_library[self.record_name] = processed
            self.save_library()
            print(f"✅ 已学习手势: {self.record_name}")
            self.is_recording = False
            self.canvas.fill(Qt.white)
        else:
            if not self.gesture_library:
                print("库中无手势，请按 R 键录制")
                return

            best_name = None
            min_score = float('inf')

            for name, template in self.gesture_library.items():
                score = frechet_distance(processed, template)
                if score < min_score:
                    min_score = score
                    best_name = name

            if min_score < 25:
                print(f"🎯 匹配成功: 【{best_name}】 (得分: {min_score:.2f})")
            else:
                print(f"❓ 未知手势 (最接近: {best_name}, 得分: {min_score:.2f})")

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.drawImage(0, 0, self.canvas)

    def nativeEvent(self, event_type, message):
        msg = wintypes.MSG.from_address(message.__int__())
        if msg.message == WM_INPUT:
            size = wintypes.UINT()
            ctypes.windll.user32.GetRawInputData(ctypes.cast(msg.lParam, ctypes.c_void_p), RID_INPUT, None, ctypes.byref(size), ctypes.sizeof(RAWINPUTHEADER))
            if size.value > 0:
                buffer = (ctypes.c_byte * size.value)()
                ctypes.windll.user32.GetRawInputData(ctypes.cast(msg.lParam, ctypes.c_void_p), RID_INPUT, buffer, ctypes.byref(size), ctypes.sizeof(RAWINPUTHEADER))
                payload = bytes(buffer)[ctypes.sizeof(RAWINPUTHEADER):]
                self.raw_touch_data_signal.emit(parse_touchpad_payload(payload))
            return True, 0
        return super().nativeEvent(event_type, message)

if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = GestureDrawingWindow()
    window.show()
    sys.exit(app.exec())