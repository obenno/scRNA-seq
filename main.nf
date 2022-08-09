#!/usr/bin/env nextflow

// A lot of codes were directly inherited from https://github.com/nf-core/rnaseq

nextflow.enable.dsl=2

// NF-CORE MODULES

include { CAT_TRIM_FASTQ } from './cat_trim_fastq' addParams( options: ['publish_files': false] )
include { STARSOLO; STARSOLO_COMPLEX; STAR_MKREF; STARSOLO_MULTIPLE; STARSOLO_MULT_SUMMARY; STARSOLO_MULT_UMI } from "./starsolo"
include { initOptions; saveFiles; getSoftwareName; getProcessName } from './modules/nf-core_rnaseq/functions'
include { QUALIMAP_RNASEQ } from './modules/nf-core/modules/qualimap/rnaseq/main'
include { CHECK_SATURATION } from "./sequencing_saturation"
include { GET_VERSIONS } from "./present_version"
include { REPORT } from "./report"


def create_fastq_channel(LinkedHashMap row) {
    def meta = [:]
    meta.id           = row.sample

    def array = []
    if (!file(row.fastq_1).exists()) {
        exit 1, "ERROR: Please check input samplesheet -> Read 1 FastQ file does not exist!\n${row.bc_read}"
    }

    if (!file(row.fastq_2).exists()) {
        exit 1, "ERROR: Please check input samplesheet -> Read 2 FastQ file does not exist!\n${row.cDNA_read}"
    }

    array = [ meta, [ file(row.fastq_1), file(row.fastq_2) ] ]

    return array
}


workflow {
    // check mandatory params
    if (!params.input) { exit 1, 'Input samplesheet not specified!' }
    if (!params.genomeDir) { exit 1, 'Genome index DIR not specified!' }
    if (!params.genomeGTF) { exit 1, 'Genome GTF not specified!' }

    Channel
    .fromPath(params.input)
    .splitCsv(header:true)
    .map{ create_fastq_channel(it) }
    .map {
        meta, fastq ->
            // meta.id = meta.id.split('_')[0..-2].join('_')
            [ meta, fastq ] }
    .groupTuple(by: [0])
    .map {
        meta, fastq ->
            return [ meta, fastq.flatten() ]
    }
    .set { ch_fastq }

    // MODULE: Concatenate FastQ files from the same sample if required
    ch_bc_read = Channel.empty()
    ch_cDNA_read = Channel.empty()
    CAT_TRIM_FASTQ( ch_fastq )
    if ( params.bc_read == "fastq_1" ){
        ch_bc_read = CAT_TRIM_FASTQ.out.read1
        ch_cDNA_read = CAT_TRIM_FASTQ.out.read2
    }else{
        ch_bc_read = CAT_TRIM_FASTQ.out.read2
        ch_cDNA_read = CAT_TRIM_FASTQ.out.read1
    }

    ch_genomeDir = file(params.genomeDir)
    ch_genomeGTF = file(params.genomeGTF)
    ch_whitelist = file(params.whitelist)
    
    ch_genome_bam                 = Channel.empty()
    ch_genome_bam_index           = Channel.empty()
    ch_starsolo_out               = Channel.empty()
    ch_star_multiqc               = Channel.empty()
    if(params.soloType == "CB_UMI_Complex"){
        ch_whitelist2 = file(params.whitelist2)
        STARSOLO_COMPLEX(
            ch_cDNA_read,
            ch_bc_read,
            ch_genomeDir,
            ch_genomeGTF,
            ch_whitelist,
            ch_whitelist2
        )
        ch_genome_bam       = STARSOLO_COMPLEX.out.bam
        ch_genome_bam_index = STARSOLO_COMPLEX.out.bai
        ch_starsolo_out     = STARSOLO_COMPLEX.out.solo_out
    }else{
        STARSOLO(
            ch_cDNA_read,
            ch_bc_read,
            ch_genomeDir,
            ch_genomeGTF,
            ch_whitelist,
        )
        ch_genome_bam       = STARSOLO.out.bam
        ch_genome_bam_index = STARSOLO.out.bai
    }

    if(params.soloMultiMappers != "Unique"){
        STARSOLO_MULTIPLE(
            STARSOLO.out.rawDir
        )
        CHECK_SATURATION(
            ch_genome_bam,
            STARSOLO_MULTIPLE.out.filteredDir,
            ch_whitelist
        )
        STARSOLO_MULT_SUMMARY(
            STARSOLO.out.cellReads_stats,
            STARSOLO_MULTIPLE.out.filteredDir,
            STARSOLO.out.summary_unique,
            CHECK_SATURATION.out.outJSON
        )
        STARSOLO_MULT_UMI(
            STARSOLO.out.cellReads_stats   
        )
        GET_VERSIONS(
            CHECK_SATURATION.out.outJSON
        )
    }else{
        CHECK_SATURATION(
            STARSOLO.out.bam,
            STARSOLO.out.filteredDir,
            ch_whitelist
        )
        GET_VERSIONS(
            CHECK_SATURATION.out.outJSON
        )
    }

    ch_qualimap_multiqc           = Channel.empty()
    QUALIMAP_RNASEQ(
        ch_genome_bam,
        ch_genomeGTF
    )
    ch_qualimap_multiqc = QUALIMAP_RNASEQ.out.results

    if(params.soloMultiMappers != "Unique"){
        REPORT(
            STARSOLO_MULT_SUMMARY.out.summary_multiple,
            STARSOLO_MULT_UMI.out.UMI_file_multiple,
            STARSOLO_MULTIPLE.out.filteredDir,
            ch_qualimap_multiqc,
            CHECK_SATURATION.out.outJSON,
            GET_VERSIONS.out.versions
        )
    }else{
        REPORT(
            STARSOLO.out.summary_unique,
            STARSOLO.out.UMI_file_unique,
            STARSOLO.out.filteredDir,
            ch_qualimap_multiqc,
            CHECK_SATURATION.out.outJSON,
            GET_VERSIONS.out.versions
        )
    }
}

workflow mkref {
    // check mandatory params
    if (!params.genomeFasta) { exit 1, 'Genome Fasta not specified!' }
    if (!params.genomeGTF) { exit 1, 'Genome GTF not specified!' }
    if (!params.refoutDir) { exit 1, 'Reference output directory not specified!'}

    ch_genomeFasta = file(params.genomeFasta)
    ch_genomeGTF = file(params.genomeGTF)
    STAR_MKREF(
        ch_genomeFasta,
        ch_genomeGTF
    )
}
