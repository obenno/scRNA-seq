#! /usr/bin/env bash


usage () {
    cat<<-EOF
	$(basename $0) <sampleID> <cellType> <starsoloSummary> <metricsOutput> <kneeDataOutput> <cloneTypeResultFile>
	
	This script is to perform some statistics from TRUST4 result
	and generate a metrics json output. User will have to provide
	sampleID, cellType and starsolo summary.csv as input, and
	define the names of three output files.
	
	cellType only support "VDJ-T" and "VDJ-B"
	
	example: $(basename $0) sampleID \\
	                        VDJ-T \\
	                        sampleID.Summary.unique.csv \\
	                        sampleID_VDJ-T.vdj_metrics.json \\
	                        sampleID_VDJ-T.knee_input.tsv \\
	                        sampleID_VDJ-T.cloneType_out.tsv
	EOF
}

if [[ $# -eq 0 ]] || [[ $1 == "-h" ]]
then
    usage
    exit 0
fi

sampleID=$1
cellType=$2
starsolo_summary=$3
metricsOut=$4
kneeInput=$5
cloneTypeResult=$6

if [[ $cellType == "VDJ-T" ]]
then
    cellName="abT"
elif [[ $cellType == "VDJ-B" ]]
then
    cellName="B"
else
    echo "cellType only supports VDJ-T and VDJ-B" &>2
    exit 1
fi


## cells were defined as chain1 (IGH or TRB) and chain2 (IGK/L or TRA) has 3 UMI in total
cellBC=$(mktemp -p ./)
awk -v cellName=$cellName '{split($3, chain1, ","); split($4, chain2, ","); chain1_umi=chain1[7]; chain2_umi=chain2[7]; if($1!="-" && $2==cellName && chain1_umi+chain2_umi>=3){print $1}}' TRUST_${sampleID}_barcode_report.tsv > $cellBC
cellNum=$(wc -l $cellBC | awk '{print $1}')

## calculate UMI in cells and background barcodes
awk 'FNR>1{split($3, chain1, ","); split($4, chain2, ","); chain1_umi=chain1[7]; chain2_umi=chain2[7]; if($1!="-"){umi=chain1_umi+chain2_umi; print $1"\t"umi}}' TRUST_${sampleID}_barcode_report.tsv |
    sort -k 2,2rn | awk 'BEGIN{"CB\tUMI"}{print}' > $kneeInput

## Extract read and umi in cells
readCBList=$(mktemp -p ./)
awk '$1~/^>/{readID=substr($1,2); getline; CB=$1; print readID"\t"CB}' TRUST_${sampleID}_toassemble_bc.fa > $readCBList
readCellList=$(mktemp -p ./)
awk 'ARGIND==1{cell[$1]}ARGIND==2{if($2 in cell){print}}' $cellBC $readCBList > $readCellList

## calculate mean/median reads per cell
meanReadsPerCell=$(awk '{print $2}' $readCellList | sort | uniq -c | awk '{print $1}' | sort -k 1,1rn | awk 'BEGIN{t=0}{t+=$1}END{print t/NR}')
medianReadsPerCell=$(awk '{print $2}' $readCellList | sort | uniq -c | awk '{a[$1]}END{asorti(a); n=length(a); if(n%2==1){print a[n/2+0.5]}else{print (a[n/2]+a[n/2+1])/2}}')

## total reads of barcode
totalReadsInCB=$(wc -l $readCBList| awk '{print $1}')
totalReadsInCell=$(wc -l $readCellList| awk '{print $1}')
fractionReadsInCells=$(awk -v cell=$totalReadsInCell -v total=$totalReadsInCB 'BEGIN{print cell/total}')

## calculate mean/median UMIs per cell, UMI of chain1 (heavy) and chain2 (light)
meanUMIsPerCell=$(head -n $cellNum $kneeInput | awk 'BEGIN{t=0}{t+=$2}END{print t/NR}')
medianUMIsPerCell=$(head -n $cellNum $kneeInput | awk '{a[$2]}END{asorti(a); n=length(a); if(n%2==1){print a[n/2+0.5]}else{print (a[n/2]+a[n/2+1])/2}}')
medianUMIsChain1=$(awk -v cellName=$cellName '{split($3, chain1, ","); split($4, chain2, ","); chain1_umi=chain1[7]; chain2_umi=chain2[7]; if($1!="-" && $2==cellName && chain1_umi+chain2_umi>=3){print $1"\t"chain1_umi}}' TRUST_${sampleID}_barcode_report.tsv | awk '{a[$2]}END{asorti(a); n=length(a); if(n%2==1){print a[n/2+0.5]}else{print (a[n/2]+a[n/2+1])/2}}')
medianUMIsChain2=$(awk -v cellName=$cellName '{split($3, chain1, ","); split($4, chain2, ","); chain1_umi=chain1[7]; chain2_umi=chain2[7]; if($1!="-" && $2==cellName && chain1_umi+chain2_umi>=3){print $1"\t"chain2_umi}}' TRUST_${sampleID}_barcode_report.tsv | awk '{a[$2]}END{asorti(a); n=length(a); if(n%2==1){print a[n/2+0.5]}else{print (a[n/2]+a[n/2+1])/2}}')

## Generate clonetype result table
awk 'ARGIND==1{a[$1]}ARGIND==2{if($1 in a){print}}' $cellBC TRUST_${sampleID}_barcode_report.tsv |
    awk '{if($3!="*"){split($3, chain1, ","); s1=chain1[6]}else{s1="NA"}; if($4!="*"){split($4, chain2, ","); s2=chain2[6]}else{s2="NA"} name1=substr($3,1,3); name2=substr($4, 1, 3); print name1":"s1";"name2":"s2}' | sort | uniq -c | sort -k 1,1rn |
    awk -v cellNum=$cellNum 'BEGIN{print "cloneType\tFrequency\tProportion"}{print $2"\t"$1"\t"$1/cellNum}' > $cloneTypeResult

## Extract metrics from starsolo summary output
## Number of Reads
totalRawReads=$(awk -F"," '$1=="Number of Reads"{print $2}' $starsolo_summary)
## Reads With Valid Barcodes
validBCreads=$(awk -F"," '$1=="Reads With Valid Barcodes"{print $2}' $starsolo_summary)
## Sequencing Saturation
saturation=$(awk -F"," '$1=="Sequencing Saturation"{print $2}' $starsolo_summary)
## Q30 Bases in CB+UMI
q30InCBandUMI=$(awk -F"," '$1=="Q30 Bases in CB+UMI"{print $2}' $starsolo_summary)
## Q30 Bases in RNA read
q30InRNA=$(awk -F"," '$1=="Q30 Bases in RNA read"{print $2}' $starsolo_summary)
## Total cloneTypes (VDJ fragments combination) Detected
totalCloneTypes=$(wc -l $cloneTypeResult| awk '{print $1-1}')

## Reads mapped to genome (U+M)
totalMappedReads=$(awk -F"," '$1=="Reads Mapped to Genome: Unique+Multiple"{print $2}' $starsolo_summary)
## Reads mapped to genome (U)
uniquelyMappedReads=$(awk -F"," '$1=="Reads Mapped to Genome: Unique"{print $2}' $starsolo_summary)


if [[ $cellType == "VDJ-B" ]]
then
    ## Calculate cells with productive V-J/V-D-J fragments (full length, with in-frame CDR3 amino acids)
    ## cells with full-length IGH chain, no matter if complete pair was found
    cellsWithFullLengthChainIGH=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if(name1=="IGH" && chain1[10]==1 && frame1!="out_of_frame"){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)
    ## cells with full-length IGK chain, no matter if complete pair was found
    cellsWithFullLengthChainIGK=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if(name2=="IGK" && chain2[10]==1 && frame2!="out_of_frame"){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)
    ## cells with full-length IGL chain, no matter if complete pair was found
    cellsWithFullLengthChainIGL=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if(name2=="IGL" && chain2[10]==1 && frame2!="out_of_frame"){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)
    ## cells with full-length V-J spanning chain (at least one chain, but not both)
    cellsWithFullLengthChain=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if((chain1[10]==1 && frame1!="out_of_frame") || (chain2[10]==1 && frame2!="out_of_frame")){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)
    ## cells with both IGH and IGK, and at least one of them is full length chain
    cellsWithFullLengthChainIGKIGH=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if(name1=="IGH" && name2=="IGK" && ((chain1[10]==1 && frame1!="out_of_frame") || (chain2[10]==1 && frame2!="out_of_frame"))){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)
    ## cells with both IGH and IGL, and at least one of them is full length chain
    cellsWithFullLengthChainIGLIGH=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if(name1=="IGH" && name2=="IGL" && ((chain1[10]==1 && frame1!="out_of_frame") || (chain2[10]==1 && frame2!="out_of_frame"))){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)


    ## Generate json metrics
    jq -n \
       --arg sampleName "$sampleID" \
       --arg totalRawReads "$totalRawReads" \
       --arg validBCreads "$validBCreads" \
       --arg saturation "$saturation" \
       --arg q30InCBandUMI "$q30InCBandUMI" \
       --arg q30InRNA "$q30InRNA" \
       --arg totalMappedReads "$totalMappedReads" \
       --arg uniquelyMappedReads "$uniquelyMappedReads" \
       --arg cells "$cellNum" \
       --arg meanReadsPerCell "$meanReadsPerCell" \
       --arg medianReadsPerCell "$medianReadsPerCell" \
       --arg totalReadsInCell "$totalReadsInCell" \
       --arg fractionReadsInCells "$fractionReadsInCells" \
       --arg meanUMIsPerCell "$meanUMIsPerCell" \
       --arg medianUMIsPerCell "$medianUMIsPerCell" \
       --arg medianUMIsChain1 "$medianUMIsChain1" \
       --arg medianUMIsChain2 "$medianUMIsChain2" \
       --arg totalCloneTypes "$totalCloneTypes" \
       --arg cellsWithFullLengthChainIGH "$cellsWithFullLengthChainIGH" \
       --arg cellsWithFullLengthChainIGK "$cellsWithFullLengthChainIGK" \
       --arg cellsWithFullLengthChainIGL "$cellsWithFullLengthChainIGL" \
       --arg cellsWithFullLengthChain "$cellsWithFullLengthChain" \
       --arg cellsWithFullLengthChainIGKIGH "$cellsWithFullLengthChainIGKIGH" \
       --arg cellsWithFullLengthChainIGLIGH "$cellsWithFullLengthChainIGLIGH" \
       '{sampleName: $sampleName, totalRawReads: $totalRawReads, validBCreads: $validBCreads, saturation: $saturation, q30InCBandUMI: $q30InCBandUMI, q30InRNA: $q30InRNA, totalMappedReads: $totalMappedReads, uniquelyMappedReads: $uniquelyMappedReads, cells: $cells, totalReadsInCell: $totalReadsInCell, meanReadsPerCell: $meanReadsPerCell, medianReadsPerCell: $medianReadsPerCell, fractionReadsInCells: $fractionReadsInCells, meanUMIsPerCell: $meanUMIsPerCell, medianUMIsPerCell: $medianUMIsPerCell, medianUMIsChain1: $medianUMIsChain1, medianUMIsChain2: $medianUMIsChain2, totalCloneTypes: $totalCloneTypes, cellsWithFullLengthChainIGH: $cellsWithFullLengthChainIGH, cellsWithFullLengthChainIGK: $cellsWithFullLengthChainIGK, cellsWithFullLengthChainIGL: $cellsWithFullLengthChainIGL, cellsWithFullLengthChain: $cellsWithFullLengthChain, cellsWithFullLengthChainIGKIGH: $cellsWithFullLengthChainIGKIGH, cellsWithFullLengthChainIGLIGH: $cellsWithFullLengthChainIGLIGH}' > $metricsOut

elif [[ $cellType == "VDJ-T" ]]
then
    ## Calculate cells with productive V-J/V-D-J fragments (full length, with in-frame CDR3 amino acids)
    ## cells with full-length IGH chain, no matter if complete pair was found
    cellsWithFullLengthChainTRB=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if(name1=="TRB" && chain1[10]==1 && frame1!="out_of_frame"){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)
    cellsWithFullLengthChainTRD=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if(name1=="TRD" && chain1[10]==1 && frame1!="out_of_frame"){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)
    ## cells with full-length IGK chain, no matter if complete pair was found
    cellsWithFullLengthChainTRA=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if(name2=="TRA" && chain2[10]==1 && frame2!="out_of_frame"){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)
    ## cells with full-length IGL chain, no matter if complete pair was found
    cellsWithFullLengthChainTRG=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if(name2=="TRG" && chain2[10]==1 && frame2!="out_of_frame"){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)
    ## cells with full-length V-J spanning chain (at least one chain, but not both)
    cellsWithFullLengthChain=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if((chain1[10]==1 && frame1!="out_of_frame") || (chain2[10]==1 && frame2!="out_of_frame")){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)
    ## cells with both IGH and IGK, and at least one of them is full length chain
    cellsWithFullLengthChainTRATRB=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if(name1=="TRB" && name2=="TRA" && ((chain1[10]==1 && frame1!="out_of_frame") || (chain2[10]==1 && frame2!="out_of_frame"))){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)
    ## cells with both IGH and IGL, and at least one of them is full length chain
    cellsWithFullLengthChainTRGTRD=$(awk 'ARGIND==1{cells[$1]}ARGIND==2{if($1 in cells){split($3, chain1, ","); split($4, chain2, ","); name1=substr(chain1[1], 1, 3); name2=substr(chain2[1], 1, 3); frame1=chain1[6]; frame2=chain2[6]; if(name1=="TRD" && name2=="TRG" && ((chain1[10]==1 && frame1!="out_of_frame") || (chain2[10]==1 && frame2!="out_of_frame"))){print $1}}}' $cellBC TRUST_${sampleID}_barcode_report.tsv| wc -l)

    jq -n \
       --arg sampleName "$sampleID" \
       --arg totalRawReads "$totalRawReads" \
       --arg validBCreads "$validBCreads" \
       --arg saturation "$saturation" \
       --arg q30InCBandUMI "$q30InCBandUMI" \
       --arg q30InRNA "$q30InRNA" \
       --arg totalMappedReads "$totalMappedReads" \
       --arg uniquelyMappedReads "$uniquelyMappedReads" \
       --arg cells "$cellNum" \
       --arg meanReadsPerCell "$meanReadsPerCell" \
       --arg medianReadsPerCell "$medianReadsPerCell" \
       --arg totalReadsInCell "$totalReadsInCell" \
       --arg fractionReadsInCells "$fractionReadsInCells" \
       --arg meanUMIsPerCell "$meanUMIsPerCell" \
       --arg medianUMIsPerCell "$medianUMIsPerCell" \
       --arg medianUMIsChain1 "$medianUMIsChain1" \
       --arg medianUMIsChain2 "$medianUMIsChain2" \
       --arg totalCloneTypes "$totalCloneTypes" \
       --arg cellsWithFullLengthChainTRB "$cellsWithFullLengthChainTRB" \
       --arg cellsWithFullLengthChainTRD "$cellsWithFullLengthChainTRD" \
       --arg cellsWithFullLengthChainTRA "$cellsWithFullLengthChainTRA" \
       --arg cellsWithFullLengthChainTRG "$cellsWithFullLengthChainTRG" \
       --arg cellsWithFullLengthChain "$cellsWithFullLengthChain" \
       --arg cellsWithFullLengthChainTRATRB "$cellsWithFullLengthChainTRATRB" \
       --arg cellsWithFullLengthChainTRGTRD "$cellsWithFullLengthChainTRGTRD" \
       '{sampleName: $sampleName, totalRawReads: $totalRawReads, validBCreads: $validBCreads, saturation: $saturation, q30InCBandUMI: $q30InCBandUMI, q30InRNA: $q30InRNA, totalMappedReads: $totalMappedReads, uniquelyMappedReads: $uniquelyMappedReads, cells: $cells, totalReadsInCell: $totalReadsInCell, meanReadsPerCell: $meanReadsPerCell, medianReadsPerCell: $medianReadsPerCell, fractionReadsInCells: $fractionReadsInCells, meanUMIsPerCell: $meanUMIsPerCell, medianUMIsPerCell: $medianUMIsPerCell, medianUMIsChain1: $medianUMIsChain1, medianUMIsChain2: $medianUMIsChain2, totalCloneTypes: $totalCloneTypes, cellsWithFullLengthChainTRB: $cellsWithFullLengthChainTRB, cellsWithFullLengthChainTRD: $cellsWithFullLengthChainTRD, cellsWithFullLengthChainTRA: $cellsWithFullLengthChainTRA, cellsWithFullLengthChainTRG: $cellsWithFullLengthChainTRG, cellsWithFullLengthChain: $cellsWithFullLengthChain, cellsWithFullLengthChainTRATRB: $cellsWithFullLengthChainTRATRB, cellsWithFullLengthChainTRGTRD: $cellsWithFullLengthChainTRGTRD}' > $metricsOut

else
    echo "cellType only supports VDJ-T and VDJ-B" &>2
    exit 1
fi

## remove temp files
rm $cellBC $readCBList $readCellList