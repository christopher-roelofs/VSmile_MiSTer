// Simulation stand-in for the Altera altddio_out megafunction as rtl/sdram.sv
// uses it (width 1: dataout follows datain_h after the rising edge and
// datain_l after the falling edge of outclock).
module altddio_out #(
    parameter extend_oe_disable = "OFF",
    parameter intended_device_family = "Cyclone V",
    parameter invert_output = "OFF",
    parameter lpm_hint = "UNUSED",
    parameter lpm_type = "altddio_out",
    parameter oe_reg = "UNREGISTERED",
    parameter power_up_high = "OFF",
    parameter width = 1
) (
    input  logic [width-1:0] datain_h,
    input  logic [width-1:0] datain_l,
    input  logic             outclock,
    input  logic             aclr,
    input  logic             aset,
    input  logic             oe,
    input  logic             outclocken,
    input  logic             sclr,
    input  logic             sset,
    output logic [width-1:0] dataout
);
    logic [width-1:0] h, l;
    always_ff @(posedge outclock) h <= datain_h;
    always_ff @(negedge outclock) l <= datain_l;
    assign dataout = outclock ? h : l;
endmodule
