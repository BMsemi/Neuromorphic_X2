module tb_pe512_system;
    timeunit 1ns; timeprecision 1ps;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, cmd_valid=0, prog_valid=0, drain_enable=0, l2_clear_valid=0;
    reg [31:0] cmd_data=0, prog_data=0;
    reg [12:0] prog_addr=0;
    reg [8:0] l2_read_addr=0;
    wire cmd_ready,prog_ready,response_valid,response_ready,l2_clear_ready;
    wire init_done,configured,busy,l2_clearing;
    wire [31:0] response_data,l2_read_data,launch_count,responses_read,responses_discarded,l2_compute_words;
    wire [5:0] command_count,response_count;
    wire [3:0] error_code;
    pe512_system dut(.*);
    integer qr[0:511],qc[0:511],queued=0,completed=0,out_col=0;
    reg [31:0] qm[0:511];
    integer gold_l2[0:511];
    integer checked_words=0, control_reads=0;
    integer cell_mode_expected=0,cell_value_expected=0;
    bit expect_cell=0, zero_weights=0, one_weights=0, random_drain=0;
    reg [31:0] lfsr=32'h12345678, held_data;
    bit held=0;
    integer i,j,r,c,tr,tc,base_completed,base_launch;
    reg [31:0] word,mask;

    function automatic integer weight_bit(input integer row,col);
        return ((row*17 + col*11 + (row/32)*3)%13)<6;
    endfunction
    function automatic integer expected_sum(input integer index,local_col);
        integer k,total;
        begin
            total=0;
            for(k=0;k<32;k=k+1)
                if(qm[index][k] && !zero_weights)
                    total=total+(one_weights ? 1 : weight_bit(qr[index]*32+k,qc[index]*32+local_col));
            return total;
        end
    endfunction
    task automatic send(input reg[31:0] data);
        begin
            @(negedge clk);cmd_valid=1;cmd_data=data;
            @(posedge clk);
            while(!cmd_ready) @(posedge clk);
            @(negedge clk);cmd_valid=0;
        end
    endtask
    task automatic pixel(input integer row,col,value,last);
        send((32'h80000000)|(row<<21)|(col<<12)|(1<<10)|(last<<9)|value);
    endtask
    task automatic expect_tile(input integer row_tile,col_tile,input reg[31:0] bits);
        begin qr[queued]=row_tile;qc[queued]=col_tile;qm[queued]=bits;queued=queued+1;end
    endtask
    task automatic tile(input integer row_tile,col_tile,input reg[31:0] bits,input integer mark_last);
        integer k;
        begin
            expect_tile(row_tile,col_tile,bits);
            for(k=0;k<32;k=k+1) pixel(row_tile*32+k,col_tile*32,bits[k],mark_last && k==31);
        end
    endtask
    task automatic idle;
        begin
            wait(completed==queued && !busy && command_count==0 && response_count==0);
            @(negedge clk);
        end
    endtask
    task automatic configure;
        begin send(32'hA203C40F);send(32'h0F030D43);send(32'h42000C03);wait(configured);end
    endtask
    task automatic clear_l2;
        begin
            wait(l2_clear_ready);@(negedge clk);l2_clear_valid=1;
            @(negedge clk);l2_clear_valid=0;wait(!l2_clearing);
            for(integer k=0;k<512;k=k+1)gold_l2[k]=0;
        end
    endtask
    task automatic check_l2;
        begin
            for(integer k=0;k<512;k=k+1)begin
                @(negedge clk);l2_read_addr=k;#1;
                if(l2_read_data!==gold_l2[k])
                    $fatal(1,"L2 mismatch column %0d actual %0d expected %0d",k,l2_read_data,gold_l2[k]);
            end
        end
    endtask
    task automatic cell_command(input integer mode,value);
        begin
            expect_cell=1;cell_mode_expected=mode;cell_value_expected=value;
            send((mode<<30)|(511<<21)|(511<<12));
            wait(!expect_cell);wait(!busy && response_count==0);@(negedge clk);
        end
    endtask

    always @(negedge clk) if(random_drain)begin
        lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        drain_enable=lfsr[0] | lfsr[2];
    end
    always @(posedge clk) if(!rst)begin
        if(command_count>32 || response_count>32)$fatal(1,"FIFO overflow");
        if(responses_discarded!=0)$fatal(1,"Discarded unread response");
        if(launch_count>completed+1)$fatal(1,"Tile launched before previous bank drained");
        if(held && (!response_valid || response_data!==held_data))
            $fatal(1,"Response changed under backpressure");
        held=response_valid && !response_ready;
        held_data=response_data;
        if(response_valid && response_ready)begin
            if(response_data[24:23]==2)begin
                if(completed>=queued)$fatal(1,"Unexpected response bank");
                if(response_data[31:25]!=0 ||
                   response_data[22:14]!=(qc[completed]*32+out_col) ||
                   response_data[13:0]!=expected_sum(completed,out_col))
                    $fatal(1,"Response mismatch tile %0d col %0d word %08x expected %0d",
                           completed,out_col,response_data,expected_sum(completed,out_col));
                gold_l2[response_data[22:14]]+=expected_sum(completed,out_col);
                checked_words++;
                if(out_col==31)begin completed++;out_col=0;end else out_col++;
            end else begin
                if(!expect_cell || response_data[24:23]!=cell_mode_expected ||
                   response_data[22:14]!=511 || response_data[13:0]!=cell_value_expected)
                    $fatal(1,"Cell response mismatch");
                expect_cell=0;control_reads++;
            end
        end
    end else held=0;
    initial begin #20000000;$fatal(1,"Simulation watchdog timeout");end

    initial begin
        for(i=0;i<512;i++)gold_l2[i]=0;
        repeat(4)@(negedge clk);rst=0;wait(init_done);configure();
        // Initialize all 262144 bits through the explicit 32-bit bulk setup port.
        for(tr=0;tr<16;tr++)for(tc=0;tc<16;tc++)for(r=0;r<32;r++)begin
            word=0;for(c=0;c<32;c++)word[c]=weight_bit(tr*32+r,tc*32+c);
            @(negedge clk);prog_addr=(tr*16+tc)*32+r;prog_data=word;prog_valid=1;
            @(posedge clk);while(!prog_ready)@(posedge clk);
            @(negedge clk);prog_valid=0;
        end
        tile(0,0,32'hffffffff,0); // Launch automatically on packet 32.
        wait(response_count==32);repeat(8)@(negedge clk);
        if(responses_read!=0 || launch_count!=1 || prog_ready || l2_clear_ready)
            $fatal(1,"Response bank/programming/clear interlock failed");
        tile(15,15,32'h80000001,1); // Entire next command burst queues but cannot execute.
        repeat(8)@(negedge clk);
        if(command_count!=32 || cmd_ready || launch_count!=1)$fatal(1,"Missing FIFO/launch backpressure");
        drain_enable=1;repeat(31)@(posedge clk);@(negedge clk);drain_enable=0;
        repeat(12)@(negedge clk);
        if(response_count!=1 || launch_count!=1 || responses_read!=31)
            $fatal(1,"Last unread response did not block next tile");
        drain_enable=1;idle();check_l2();
        $display("PASS: shared FIFO full/partial drain, queued next tile, last-word interlock");

        expect_tile(7,3,0);pixel(7*32+4,3*32,0,1);idle();
        expect_tile(6,8,0);pixel(6*32+5,8*32,1,0);pixel(6*32+5,8*32,0,1);idle();
        base_launch=launch_count;pixel(0,0,1,0);pixel(32,0,1,1);
        repeat(5)@(negedge clk);
        if(error_code!=2 || launch_count!=base_launch)$fatal(1,"Cross-tile burst not rejected");
        pixel(0,0,2,1);repeat(5)@(negedge clk);
        if(error_code!=1 || launch_count!=base_launch)$fatal(1,"Nonbinary command not rejected");
        tile(2,5,32'h55555555,1);idle();
        $display("PASS: zero activation, duplicate-row overwrite, invalid burst rejection/recovery");
        clear_l2();base_completed=completed;base_launch=launch_count;
        random_drain=1;
        for(tr=0;tr<16;tr++)for(tc=0;tc<16;tc++)begin
            mask=0;for(r=0;r<32;r++)mask[r]=((tr*7+r*3+tc)%5)<3;
            tile(tr,tc,mask,1);
        end
        idle();random_drain=0;drain_enable=1;
        if(completed-base_completed!=256 || launch_count-base_launch!=256 ||
           l2_compute_words!=8192)$fatal(1,"Full array coverage count mismatch");
        check_l2();
        $display("PASS: all 256 tiles, 8192 ordered responses, all 512 L2 sums, randomized backpressure");
        cell_command(3,1);cell_command(1,1);cell_command(0,0);cell_command(1,0);
        if(control_reads!=4)$fatal(1,"Cell programming/readback failed");
        $display("PASS: SET/READ/RESET use same FIFO pair; control responses excluded from L2");
        for(r=0;r<32;r++)begin
            @(negedge clk);prog_addr=(3*16+4)*32+r;prog_data=32'hffffffff;prog_valid=1;
            @(posedge clk);while(!prog_ready)@(posedge clk);
            @(negedge clk);prog_valid=0;
        end
        one_weights=1;tile(3,4,32'hffffffff,1);idle();one_weights=0;
        $display("PASS: all-one tile produces exactly 32 in every column");
        // Reset while a response bank is waiting, then require deterministic zero weights.
        drain_enable=0;tile(0,0,32'hffffffff,1);wait(response_count==32);
        @(negedge clk);rst=1;repeat(4)@(negedge clk);
        queued=0;completed=0;out_col=0;checked_words=0;zero_weights=1;
        for(i=0;i<512;i++)gold_l2[i]=0;
        rst=0;wait(init_done);configure();drain_enable=1;
        tile(15,15,32'hffffffff,1);idle();check_l2();
        if(launch_count!=1 || responses_read!=32 || responses_discarded!=0)
            $fatal(1,"Reset recovery counter mismatch");
        $display("PASS: reset while blocked, RAM scrub and clean restart");
        $display("ALL_SHARED_PE_TESTS_PASSED");$finish;
    end
endmodule
