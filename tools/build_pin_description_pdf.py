"""Build the customer-facing Neuromorphic X2 AHB pin-description PDF."""

from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "doc" / "Pin Description.pdf"
PAGE_W, PAGE_H = A4
NAVY = colors.HexColor("#17365D")
BLUE = colors.HexColor("#2F75B5")
PALE_YELLOW = colors.HexColor("#FFF2CC")
LIGHT = colors.HexColor("#F3F6F9")
GREY = colors.HexColor("#666666")


def header_footer(canvas, doc):
    canvas.saveState()
    canvas.setFillColor(NAVY)
    canvas.rect(0, PAGE_H - 16 * mm, PAGE_W, 16 * mm, fill=1, stroke=0)
    canvas.setFillColor(colors.white)
    canvas.setFont("Helvetica-Bold", 10)
    canvas.drawString(16 * mm, PAGE_H - 10 * mm, "Neuromorphic X2 - AHB Interface")
    canvas.setFillColor(GREY)
    canvas.setFont("Helvetica", 8)
    canvas.drawString(16 * mm, 10 * mm, "BM LABS | Customer collateral | 30 October 2026")
    canvas.drawRightString(PAGE_W - 16 * mm, 10 * mm, f"Page {doc.page}")
    canvas.restoreState()


styles = getSampleStyleSheet()
styles.add(ParagraphStyle(name="CoverTitle", parent=styles["Title"], fontName="Helvetica-Bold", fontSize=25, leading=30, textColor=NAVY, alignment=TA_CENTER, spaceAfter=8 * mm))
styles.add(ParagraphStyle(name="CoverSub", parent=styles["Normal"], fontSize=13, leading=18, textColor=BLUE, alignment=TA_CENTER, spaceAfter=10 * mm))
styles.add(ParagraphStyle(name="H1X", parent=styles["Heading1"], fontName="Helvetica-Bold", fontSize=18, leading=22, textColor=NAVY, spaceBefore=3 * mm, spaceAfter=4 * mm))
styles.add(ParagraphStyle(name="H2X", parent=styles["Heading2"], fontName="Helvetica-Bold", fontSize=12, leading=15, textColor=BLUE, spaceBefore=3 * mm, spaceAfter=2 * mm))
styles.add(ParagraphStyle(name="BodyX", parent=styles["BodyText"], fontSize=9.2, leading=13, spaceAfter=2.5 * mm))
styles.add(ParagraphStyle(name="SmallX", parent=styles["BodyText"], fontSize=7.5, leading=10))
styles.add(ParagraphStyle(name="WarnX", parent=styles["BodyText"], fontSize=9, leading=13, textColor=colors.HexColor("#7F6000"), borderColor=colors.HexColor("#D6B656"), borderWidth=0.8, borderPadding=7, backColor=PALE_YELLOW, spaceBefore=4 * mm, spaceAfter=4 * mm))


def p(text, style="BodyX"):
    return Paragraph(text, styles[style])


def make_table(rows, widths, repeat=1):
    cooked = [[p(str(cell), "SmallX") for cell in row] for row in rows]
    table = Table(cooked, colWidths=widths, repeatRows=repeat, hAlign="LEFT")
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), NAVY),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("GRID", (0, 0), (-1, -1), 0.35, colors.HexColor("#B8C2CC")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, LIGHT]),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    return table


AHB_ROWS = [
    ["Signal", "Dir", "Width", "Description"],
    ["HCLK", "In", "1", "AHB clock. Address/control and data phases are sampled on rising edges."],
    ["HRESETn", "In", "1", "Active-low asynchronous interface reset."],
    ["HSEL", "In", "1", "Subordinate select from the address decoder."],
    ["HADDR", "In", "32", "Byte address. Default model match is 0xE000_0004."],
    ["HTRANS", "In", "2", "Transfer type. HTRANS[1]=1 identifies NONSEQ or SEQ active transfers."],
    ["HWRITE", "In", "1", "1 for write; 0 for read."],
    ["HSIZE", "In", "3", "Transfer size. Use 3'b010 for the supported 32-bit word access."],
    ["HBURST", "In", "3", "Burst type. Accepted for bus compatibility; use single word transfers."],
    ["HPROT", "In", "4", "Protection attributes. Accepted for integration compatibility."],
    ["HMASTER", "In", "4", "Master identifier. Accepted for integration compatibility."],
    ["HMASTLOCK", "In", "1", "Locked-transfer qualifier. Accepted for integration compatibility."],
    ["HWDATA", "In", "32", "Write data, sampled in the AHB write data phase."],
    ["HREADY", "In", "1", "Upstream transfer-ready input. A new address phase is accepted only when high."],
    ["HRDATA", "Out", "32", "Read result word or empty-read sentinel."],
    ["HREADYOUT", "Out", "1", "Transfer completion. Low inserts wait states."],
    ["HRESP", "Out", "2", "2'b00 OKAY; 2'b01 ERROR for unsupported address, size, or transfer conditions."],
]

PHYSICAL_ROWS = [
    ["Signal", "Dir", "Description"],
    ["user_clk", "In", "Implementation clock used by the physical macro control domain."],
    ["user_rst", "In", "Implementation reset used by the physical macro control domain."],
    ["TM", "In", "Test-mode enable."],
    ["ScanInCC", "In", "Scan input for the column-control chain."],
    ["ScanInDL", "In", "Scan input for the left data chain."],
    ["ScanInDR", "In", "Scan input for the right data chain."],
    ["ScanOutCC", "Out", "Scan output for the column-control chain."],
    ["VDDC1, VDDC2", "Power", "Digital core supplies."],
    ["VDDA1, VDDA2", "Power", "Analog supplies."],
    ["VSS", "Ground", "Common ground."],
    ["Vcc_wl_read", "Analog", "Read word-line bias supply."],
    ["Vcc_wl_set", "Analog", "SET word-line bias supply."],
    ["Vcc_wl_reset", "Analog", "RESET word-line bias supply."],
    ["Vcc_set", "Analog", "SET bias supply."],
    ["Vcc_read", "Analog", "Read bias supply."],
    ["dc_bias", "Analog", "DC bias input."],
    ["Iref", "Analog", "Reference-current input."],
    ["Vbias", "Analog", "Analog bias-voltage input."],
    ["Vcomp", "Analog", "Comparator reference input."],
    ["Bias_comp2", "Analog", "Secondary comparator bias input."],
]

COMMAND_ROWS = [
    ["Bits", "Field", "Definition"],
    ["31:30", "Mode", "00 RESET, 01 READ, 10 COMPUTE, 11 SET"],
    ["29:21", "Row", "9-bit global row address, 0-511"],
    ["20:12", "Column", "9-bit global column address, 0-511"],
    ["11", "Status request", "Return FSM error/status on the associated read"],
    ["10", "Compute all", "Return all 32 columns in the selected 32-column bank"],
    ["9", "Compute start", "Final COMPUTE packet and launch marker"],
    ["8", "Reserved", "Write zero"],
    ["7:0", "PWM", "Pulse-width/input activation value"],
]

RESULT_ROWS = [
    ["Bits", "Field", "Definition"],
    ["31:25", "Reserved", "Zero"],
    ["24:23", "Mode", "Operation that produced the result"],
    ["22:14", "Column", "Global minuend column address"],
    ["13:8", "Coarse", "Upper six bits of the signed 14-bit differential count"],
    ["7:0", "Fine", "Lower eight bits of the signed 14-bit differential count"],
]


def build_story():
    return [
        Spacer(1, 22 * mm),
        p("Neuromorphic X2", "CoverTitle"),
        p("512 x 512 ReRAM Compute-in-Memory Macro", "CoverSub"),
        p("32-bit AHB Subordinate Interface<br/>Pin Description and Integration Rules", "CoverSub"),
        Spacer(1, 10 * mm),
        make_table([
            ["Property", "Value"],
            ["Model", "Neuromorphic_X2_ahb_beh"],
            ["Default register address", "0xE000_0004"],
            ["AHB data width", "32 bits"],
            ["Crossbar", "512 rows x 512 columns"],
            ["Command / response FIFOs", "32 entries / 32 entries"],
            ["Document revision", "2.0 - 30 October 2026"],
        ], [55 * mm, 95 * mm]),
        p("The behavioral interface is an AHB subordinate and is compatible with a standards-compliant 32-bit AHB master when the address, transfer-size, and handshake requirements in this document are followed.", "WarnX"),
        p("Physical-view qualification notice", "H2X"),
        p("The included GDS, LEF, and Liberty files are provisional interface-alignment views. Regenerate and sign off an implemented AHB macro with synthesis, place-and-route, DRC/LVS, extraction, and timing/power characterization before fabrication."),
        PageBreak(),
        p("AHB signal reference", "H1X"),
        p("A transfer is active when HSEL=1, HTRANS[1]=1, and upstream HREADY=1. The model supports 32-bit word accesses at the configured data-register address."),
        make_table(AHB_ROWS, [30 * mm, 12 * mm, 14 * mm, 116 * mm]),
        PageBreak(),
        p("Physical macro, scan, and analog pins", "H1X"),
        p("These pins are retained in the provisional physical views. Their electrical limits and production test sequence must be taken from the final characterized macro release."),
        make_table(PHYSICAL_ROWS, [40 * mm, 18 * mm, 114 * mm]),
        p("Behavioral-only observability", "H2X"),
        p("The behavioral HDL also exposes scan/test observability ports named i_scan_si1, i_scan_se1, i_TM, o_TM, o_mux_sel, and 512-bit source-line, bit-line, and word-line state buses. These are simulation observability signals and are not a replacement for final hard-macro scan collateral."),
        PageBreak(),
        p("Transaction and frame rules", "H1X"),
        p("Reset", "H2X"),
        p("Hold HRESETn low to reset the AHB interface, command state, and output queue. After release, the first three accepted writes are configuration words. They do not execute array commands."),
        p("Writes", "H2X"),
        p("Drive the address/control phase at 0xE000_0004 with HWRITE=1 and HSIZE=3'b010, then drive HWDATA in the following data phase. Hold the transfer stable while HREADYOUT is low."),
        make_table(COMMAND_ROWS, [23 * mm, 38 * mm, 111 * mm]),
        p("Reads", "H2X"),
        p("Drive HWRITE=0. HREADYOUT remains low until a queued result is available. HRDATA and HRESP are valid when HREADYOUT returns high."),
        make_table(RESULT_ROWS, [23 * mm, 38 * mm, 111 * mm]),
        p("Differential signed-column convention", "H2X"),
        p("Physical columns are paired as (2*n, 2*n+1). Result 2*n is column[2*n] - column[2*n+1], and result 2*n+1 is the opposite difference. Result bits [22:14] identify the minuend column; bits [13:0] contain the signed 14-bit two's-complement difference."),
        p("Compute-all bank selection", "H2X"),
        p("When command bit 10 is set, the command column selects one 32-column bank. For example, column 68 selects columns 64 through 95. The model queues exactly 32 results with global column addresses."),
    ]


def main():
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    doc = SimpleDocTemplate(str(OUTPUT), pagesize=A4, rightMargin=16 * mm, leftMargin=16 * mm, topMargin=22 * mm, bottomMargin=16 * mm, title="Neuromorphic X2 AHB Pin Description", author="BM LABS", subject="512 x 512 AHB interface and physical macro pins")
    doc.build(build_story(), onFirstPage=header_footer, onLaterPages=header_footer)
    print(OUTPUT)


if __name__ == "__main__":
    main()

