#!/usr/bin/env python3
"""
QoS CSV xApp for Master's Thesis data collection.
Writes every KPM Style-1 indication to a CSV file tagged with
experiment name and traffic type (set via env vars EXPERIMENT / TRAFFIC_TYPE).
"""

import argparse
import csv
import os
import signal
import sys
from lib.xAppBase import xAppBase

METRICS = [
    "DRB.UEThpDl",
    "DRB.UEThpUl",
    "DRB.RlcSduDelayDl",
    # DRB.PdcpSduVolumeDL and DRB.PdcpSduVolumeUL require enable_pdcp: true in gNB metrics config
    # DRB.PacketSuccessRateUlgNBUu may not be supported by srsRAN E2SM-KPM Style 1
    # Adding unsupported metrics causes gNB to reject the entire action def with E2NodeCause(Cause:6, Value:0)
]

FIELDNAMES = ["timestamp", "experiment", "traffic_type", "5qi",
              "DRB.UEThpDl", "DRB.UEThpUl", "DRB.RlcSduDelayDl"]


class QosCsvXapp(xAppBase):
    def __init__(self, config, http_server_port, rmr_port, csv_path, experiment, traffic_type, qos_5qi, label_file=None):
        super().__init__(config, http_server_port, rmr_port)
        self.csv_path = csv_path
        self.experiment = experiment
        self.traffic_type = traffic_type
        self.qos_5qi = qos_5qi
        self.label_file = label_file  # optional file: "<traffic_type>,<5qi>" — read on every callback
        self._init_csv()
        self.row_count = 0

    def _init_csv(self):
        write_header = not os.path.exists(self.csv_path) or os.path.getsize(self.csv_path) == 0
        self._csv_file = open(self.csv_path, "a", newline="")
        self._writer = csv.DictWriter(self._csv_file, fieldnames=FIELDNAMES)
        if write_header:
            self._writer.writeheader()
            self._csv_file.flush()

    def my_subscription_callback(self, e2_agent_id, subscription_id, indication_hdr, indication_msg):
        # Refresh label from file if provided (allows campaign script to update mid-run)
        if self.label_file and os.path.exists(self.label_file):
            try:
                parts = open(self.label_file).read().strip().split(",")
                self.traffic_type = parts[0]
                if len(parts) > 1:
                    self.qos_5qi = parts[1]
            except Exception:
                pass

        hdr = self.e2sm_kpm.extract_hdr_info(indication_hdr)
        data = self.e2sm_kpm.extract_meas_data(indication_msg)

        meas = data.get("measData", {})
        row = {
            "timestamp":   str(hdr.get("colletStartTime", "")),
            "experiment":  self.experiment,
            "traffic_type": self.traffic_type,
            "5qi":         self.qos_5qi,
            "DRB.UEThpDl":  self._val(meas, "DRB.UEThpDl"),
            "DRB.UEThpUl":  self._val(meas, "DRB.UEThpUl"),
            "DRB.RlcSduDelayDl": self._val(meas, "DRB.RlcSduDelayDl"),
        }
        self._writer.writerow(row)
        self._csv_file.flush()
        self.row_count += 1
        print(f"[{self.row_count:04d}] {row['timestamp']} | {self.traffic_type:10s} 5QI={self.qos_5qi} "
              f"DL={str(row['DRB.UEThpDl']):>8} UL={str(row['DRB.UEThpUl']):>8} "
              f"DelayDl={str(row['DRB.RlcSduDelayDl']):>8}", flush=True)

    @staticmethod
    def _val(meas, key):
        v = meas.get(key, [0.0])
        if isinstance(v, list):
            return v[0] if v else 0.0
        return v

    @xAppBase.start_function
    def start(self, e2_node_id, metric_names):
        print(f"[QosCsvXapp] experiment={self.experiment} traffic={self.traffic_type} "
              f"5qi={self.qos_5qi} csv={self.csv_path}", flush=True)
        self.e2sm_kpm.subscribe_report_service_style_1(
            e2_node_id, 1000, metric_names, 1000, self.my_subscription_callback)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="QoS CSV data-collection xApp")
    parser.add_argument("--config",           type=str, default="")
    parser.add_argument("--http_server_port", type=int, default=8093)
    parser.add_argument("--rmr_port",         type=int, default=4563)
    parser.add_argument("--e2_node_id",       type=str, default="gnbd_999_070_00019b_0")
    parser.add_argument("--ran_func_id",      type=int, default=2)
    parser.add_argument("--csv",              type=str, default="/tmp/kpm_data.csv")
    parser.add_argument("--experiment",       type=str,
                        default=os.environ.get("EXPERIMENT", "no_qos"))
    parser.add_argument("--traffic_type",     type=str,
                        default=os.environ.get("TRAFFIC_TYPE", "bulk"))
    parser.add_argument("--5qi",              dest="qos_5qi", type=str,
                        default=os.environ.get("QOS_5QI", "9"))
    parser.add_argument("--label_file",       type=str, default=None,
                        help="File containing '<traffic_type>,<5qi>' — re-read on every KPM callback")

    args = parser.parse_args()

    xapp = QosCsvXapp(
        args.config, args.http_server_port, args.rmr_port,
        args.csv, args.experiment, args.traffic_type, args.qos_5qi, args.label_file)
    xapp.e2sm_kpm.set_ran_func_id(args.ran_func_id)

    signal.signal(signal.SIGQUIT, xapp.signal_handler)
    signal.signal(signal.SIGTERM, xapp.signal_handler)
    signal.signal(signal.SIGINT, xapp.signal_handler)

    xapp.start(args.e2_node_id, METRICS)
