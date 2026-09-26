 module pipeline_flush (
    input branch_pred,      
    input branch_taken,      
    output flush          
);

assign flush = (branch_pred != branch_taken);

endmodule