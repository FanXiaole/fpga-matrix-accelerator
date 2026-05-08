# FPGA Matrix Accelerator 🚀

A high-performance hardware-based matrix engine designed on FPGA, featuring low-level acceleration for matrix arithmetic and image convolution.

## 👥 The Team
*A cross-disciplinary collaboration merging AI algorithms with hardware architecture.*

| Member | Department | Core Responsibility |
| :--- | :--- | :--- |
| **Jin Yihan** | **Dept. of CS** | Top-level Architecture, Input Logic & Project Documentation |
| **Yang Weiming** | School of AI | Data Storage, Generation & UART Communication Protocols |
| **Justin Fan** | School of AI | **ALU, Display Engine & Convolution Hardware Acceleration** |

## ✨ Key Features
* **Core Ops**: Transpose, Addition, Scalar Mul, Matrix Multiplication.
* **🚀 Convolution Accel (Bonus)**: 3x3 sliding window with MAC pipeline design for pixel-level streaming.
* **🖥️ Smart Display (Bonus)**: Grid-aligned terminal output with Signed/BCD logic support.
* **🛡️ Robust Design**: Signal debouncing, fail-safe recovery, and 100% decoupled Calc/Display logic.

## 🛠 Technical Highlights
* **Distributed FSM**: Replaced bloated top-level jumps with modular "Routing + Autonomy" logic.
* **SRP Compliance**: Strictly adhered to Single Responsibility Principle to eliminate UART resource contention.
* **Hardware Logic**: Pure Verilog implementation optimized for timing and resource constraints.

## 🧠 Individual Reflection (Justin Fan)

Transitioning from high-level AI abstractions to raw hardware logic was a transformative journey. Responsible for the **ALU and Convolution Acceleration**, I had to dismantle my "software loop" bias and rebuild my logic using pipelines and state machines. 

This project was the first time I truly felt the "friction" of hardware—optimizing MAC resources and managing timing constraints in real-time. It bridged the gap between code and silicon for me, turning **Hardware-Software Co-design** from a textbook concept into a visceral engineering passion. This repository marks my first steps into the "magical" world of computer architecture.

---
*Built with Verilog, Logic, and Grit.*
