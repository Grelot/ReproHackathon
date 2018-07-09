#require "bistro bistro.bioinfo bistro.utils core"

open Core.Std
open Bistro.Std
open Bistro.EDSL
open Bistro_bioinfo.Std

let ( % ) f g x = g (f x)

let cat xs =
  workflow [
    cmd "cat" ~stdout:dest [
      list ~sep:" " dep xs ;
    ]
  ]

let select p w = w / p

module Ucsc_gb = struct
  include Ucsc_gb

  let chromosome_sequence org chr =
    let org = string_of_genome org in
    let url =
      sprintf
        "ftp://hgdownload.cse.ucsc.edu/goldenPath/%s/chromosomes/%s.fa.gz"
        org chr
    in
    let descr = sprintf "ucsc_gb.chromosome_sequence(%s,%s)" org chr in
    workflow ~descr [
      wget ~dest:(tmp // "seq.fa.gz") url ;
      cmd "gunzip" [ tmp // "seq.fa.gz" ] ;
      cmd "mv" [ tmp // "seq.fa" ; dest ] ;
    ]
end

module Star = struct
  let env = docker_image ~account:"flemoine" ~name:"star" ()

  let index (fa : fasta workflow) =
    workflow ~descr:"star.index" ~np:8 ~mem:(30 * 1024) [
      mkdir_p dest ;
      cmd "STAR" ~env [
        opt "--runThreadN" ident np ;
        opt "--runMode" string "genomeGenerate" ;
        opt "--genomeDir" ident dest ;
        opt "--genomeFastaFiles" dep fa ;
      ]
    ]

  let map idx (fq1, fq2) : [`STAR] directory workflow =
    workflow ~descr:"star.map" ~np:8 ~mem:(30 * 1024) [
      mkdir_p dest ;
      cmd "STAR" ~stdout:(dest // "sorted.bam") ~env [
        opt "--outFileNamePrefix" ident (dest // "star") ;
        opt "--runThreadN" ident np ;
        opt "--outSAMstrandField" string "intronMotif" ;
        opt "--outFilterMismatchNmax" int 4 ;
        opt "--outFilterMultimapNmax" int 10 ;
        opt "--genomeDir" dep idx ;
        opt "--readFilesIn" ident (seq ~sep:" " [ dep fq1 ; dep fq2 ]) ;
        opt "--outSAMunmapped" string "None" ;
        opt "--outSAMtype" string "BAM SortedByCoordinate" ;
        opt "--outStd" string "BAM_SortedByCoordinate" ;
        opt "--genomeLoad" string "NoSharedMemory" ;
        opt "--limitBAMsortRAM" ident mem ;
      ]
    ]

  let sorted_mapped_reads = selector ["sorted.bam"]
end

module DEXSeq = struct
  let env = docker_image ~account:"flemoine" ~name:"r-rnaseq" ()

  let prepare_annotation gff =
    workflow ~descr:"dexseq.prepare_annotation" [
      cmd "python" ~env [
        string "/usr/local/lib/R/library/DEXSeq/python_scripts/dexseq_prepare_annotation.py" ;
        dep gff ;
        dest ;
      ]
    ]

  let counts gff (bam : bam workflow) =
    workflow ~descr:"dexseq.counts" [
      cmd "python" ~env [
        string "/usr/local/lib/R/library/DEXSeq/python_scripts/dexseq_count.py" ;
        opt "-p" string "yes" ;
        opt "-r" string "pos" ;
        opt "-s" string "no" ;
        opt "-f" string "bam" ;
        dep gff ;
        dep bam ;
        dest ;
      ]
    ]
end

module Kissplice = struct
  let env = docker_image ~account:"pveber" ~name:"kissplice" ~tag:"2.4.0" ()

  let kissplice k (fq1 : 'a fastq workflow) (fq2 : 'a fastq workflow) : [`kissplice] directory workflow =
    workflow ~descr:"kissplice" ~np:8 ~mem:(4 * 1024) [
      mkdir_p dest ;
      cmd "kissplice" ~env [
        opt "-r" dep fq1 ;
        opt "-r" dep fq2 ;
        opt "-k" int k ;
        opt "-o" ident dest ;
        opt "-d" ident tmp ;
        opt "-t" ident np ;
        opt "--max-memory" ident mem ;
      ]
    ]
end

let sratoolkit_env =
  docker_image ~account:"pveber" ~name:"sra-toolkit" ~tag:"2.8.0" ()

let opt_mapped_reads idx (sra : sra workflow) =
  let gunzip fq =
    seq ~sep:"" [
      string "<(gunzip -c " ; fq ; string ")"
    ]
  in
  let fqgz n = tmp // (sprintf "reads_%d.fastq.gz" n) in
  workflow ~descr:"opt_mapped_reads" ~np:8 ~mem:(10 * 1024) [
    mkdir_p tmp ;
    cmd ~env:sratoolkit_env "fastq-dump" [
      opt "-O" ident tmp ;
      string "--split-files" ;
      dep sra
    ] ;
    mv (tmp // "*_1.fastq.gz") (fqgz 1) ;
    mv (tmp // "*_2.fastq.gz") (fqgz 2) ;
    cmd "STAR" ~stdout:dest ~env:Star.env [
      opt "--runThreadN" ident np ;
      opt "--outSAMstrandField" string "intronMotif" ;
      opt "--outFilterMismatchNmax" int 4 ;
      opt "--outFilterMultimapNmax" int 10 ;
      opt "--genomeDir" dep idx ;
      opt "--readFilesIn" ident (seq ~sep:" " [ gunzip (fqgz 1) ;
                                                gunzip (fqgz 2) ]) ;
      opt "--outSAMunmapped" string "None" ;
      opt "--outSAMtype" string "BAM SortedByCoordinate" ;
      opt "--outStd" string "BAM_SortedByCoordinate" ;
      opt "--genomeLoad" string "NoSharedMemory" ;
      opt "--limitBAMsortRAM" ident mem ;
    ]
  ]

let fastq_dump_head_dir n sra =
  workflow ~descr:"fastq-dump-head" [
    mkdir_p tmp ;
    mkdir_p dest ;
    pipe [
      cmd ~env:sratoolkit_env "fastq-dump" [ string "-Z" ; dep sra ] ;
      cmd "head" [ opt "-n" int (n * 4 * 2) ] ;
      cmd "gawk" [
        seq ~sep:"" [
          string  "'{ if ((NR - 1) % 8 < 4) print $0 > " ;
          quote ~using:'"' (dest // "reads_1.fastq") ;
          string " ; else print $0 > " ;
          quote ~using:'"' (dest // "reads_2.fastq") ;
          string "}'"
        ]
      ]
    ] ;
  ]

let fastq_dump_head n sra =
  let d = fastq_dump_head_dir n sra in
  d / selector [ "reads_1.fastq" ],
  d / selector [ "reads_2.fastq" ]

let dexseq_script = {rscript|
library(DEXSeq)
library(reshape2)
options(bitmapType='cairo')

## Count data
counts<-read.table(count_file)
colnames(counts)=c("cond","sraid","exon","count")
widecount=dcast(counts, exon ~ sraid,value.var="count")
row.names(widecount)=widecount$exon
widecount=widecount[,-1]

## Exon and Gene Names
exons=sapply(strsplit(row.names(widecount), ":"),"[",2)
genes=sapply(strsplit(row.names(widecount), ":"),"[",1)

## Sample Annotation
samples=unique(counts[,c(1,2)])$cond
sampleTable <- data.frame(lapply(unique(counts[,c(1,2)]), as.character),libType="paired-end",stringsAsFactors=FALSE)
row.names(sampleTable)=sampleTable$sraid
sampleTable=sampleTable[,-2]
colnames(sampleTable)=c("condition","libType")
# on remet dans l'ordre
sampleTable=sampleTable[colnames(widecount),]

# Write into individual files
countfiles=paste0(colnames(widecount),".txt")
for(sample in colnames(widecount)){
write.table(file=paste0(sample,".txt"),data.frame(row.names=row.names(widecount),count=widecount[,sample]),row.names=TRUE,col.names=FALSE,quote=FALSE,sep="\t")
}

# Create DEXSeqDataSet
dxd= DEXSeqDataSetFromHTSeq(countfiles,sampleData=sampleTable,design=~sample+exon+condition:exon,flattenedfile=annot)

# Stat analysis
dxd=estimateSizeFactors(dxd)
dxd=estimateDispersions(dxd)

png("dispersion_out.png")
plotDispEsts(dxd)
dev.off()

dxd=testForDEU(dxd)
dxd=estimateExonFoldChanges(dxd,fitExpToVar="condition")
dxr1=DEXSeqResults( dxd )
dxr1=na.omit(dxr1)
#table(dxr1$pvalue<0.1)
write.table(file="diff_exons_out.txt",dxr1[dxr1$padj<0.1,])
#table(tapply(dxr1$padj<0.1,dxr1$groupID,any))

png("maplot_out.png")
plotMA(dxr1,cex=0.8)
dev.off()

#for(i in unique(dxr1[dxr1$padj<0.1,"groupID"])){
#  png(paste0(i,"_out.png"))
#  plotDEXSeq( dxr1,i,legend=TRUE,cex.axis=1.2,cex=1.3,lwd=2,norCounts=TRUE,splicing=TRUE,displayTranscripts=TRUE)
#  dev.off()
#}
|rscript}

let assign var path =
  seq ~sep:" " [ string var ; string " <-" ; quote ~using:'"' path ]

let dexseq_script counts annot = seq ~sep:"\n" [
    string "#!/usr/bin/env Rscript" ;
    assign "dest" dest ;
    assign "count_file" (dep counts) ;
    assign "annot" (dep annot) ;
    string dexseq_script ;
  ]

let dexseq counts annot =
  workflow ~descr:"dexseq" [
    mkdir_p dest ;
    docker DEXSeq.env (
      and_list [
        cd dest ;
        cmd "Rscript" [ file_dump (dexseq_script counts annot) ]
      ]
    )
  ]


type condition =
  | Mutated
  | WT

let string_of_condition = function
  | Mutated -> "mut"
  | WT -> "wt"

let mapped_counts cond id counts =
  workflow ~descr:"mapped.counts" [
    pipe [
      cmd "grep" [
        opt "-v" (string % quote ~using:'"') "^_" ;
        dep counts ;
      ] ;
      cmd "awk" ~stdout:dest [
        string (sprintf {|'{print "%s\t%s\t" $0}'|} (string_of_condition cond) id) ;
      ]
    ]
  ]






let srr_samples_ids = function
  | Mutated -> [
      "SRR628582" ;
      "SRR628583" ;
      "SRR628584" ;
    ]
  | WT -> [
      "SRR628585" ;
      "SRR628586" ;
      "SRR628587" ;
      "SRR628588" ;
      "SRR628589" ;
    ]

let fetch_sra x =
  Unix_tools.wget (sprintf "http://appliances.france-bioinformatique.fr/reprohackathon/%s.sra" x)

let sample x =
  Sra_toolkit.fastq_dump_pe (fetch_sra x)

let genome = Ucsc_gb.genome_sequence `hg38

let gff = Ensembl.gff ~chr_name:`ucsc ~release:87 ~species:`homo_sapiens

type mode = {
  reads : [`all | `head of int] ;
  genome : [`all | `chromosome of string] ;
}

let mode ?chr ?reads () =
  {
    genome = (
      match chr with
      | None -> `all
      | Some chr -> `chromosome chr
    ) ;
    reads = (
      match reads with
      | None -> `all
      | Some n -> `head n
    ) ;
  }

let pipeline mode =
  let org = `hg38 in
  let fastq_dump = match mode.reads with
    | `head n -> fastq_dump_head n
    | `all -> Sra_toolkit.fastq_dump_pe
  in
  let genome = match mode.genome with
    | `all -> Ucsc_gb.genome_sequence org
    | `chromosome chr -> Ucsc_gb.chromosome_sequence org "chr20"
  in
  let star_index = Star.index genome in
  let annot = DEXSeq.prepare_annotation gff in
  let sample cond id =
    fetch_sra id
    |> fastq_dump
    |> Star.map star_index
    |> select Star.sorted_mapped_reads
    |> DEXSeq.counts annot
    |> mapped_counts cond id
  in
  let counts cond = List.map (srr_samples_ids cond) ~f:(sample cond) in
  let all_counts = cat (counts Mutated @ counts WT) in
  let dexseq = dexseq all_counts in
  Bistro_repo.[
    [ "precious" ; "star_index" ] %> star_index ;
    [ "dexseq" ] %> dexseq annot ;
  ]

let logger =
  Bistro_logger.tee
    (Bistro_console_logger.create ())
    (Bistro_html_logger.create "report.html")

let () =
  mode ~chr:"chr20" ~reads:1_000_000 ()
  |> pipeline
  |> Bistro_repo.build
    ~np:8 ~mem:(30 * 1024)
    ~keep_all:true
    ~logger
    ~outdir:"res"
