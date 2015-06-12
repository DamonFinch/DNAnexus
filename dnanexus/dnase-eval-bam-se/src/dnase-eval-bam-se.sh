#!/bin/bash
# dnase-eval-bam-se.sh - Evaluates (single-end) bam and returns with chrM filtered out and small sample for the ENCODE DNase-seq pipeline.

script_name="dnase-eval-bam-se.sh"
script_ver="0.2.1"

main() {
    echo "* Installing phantompeakqualtools, caTools, snow and spp..." 2>&1 | tee -a install.log
    set -x
    # phantompeakqualtools  : also resquires boost C libraries (on aws), boost C libraries (on aws) samtools (in resources/usr/bin)
    wget https://phantompeakqualtools.googlecode.com/files/ccQualityControl.v.1.1.tar.gz -O phantompeakqualtools.tgz >> install.log 2>&1
    mkdir phantompeakqualtools
    tar -xzf phantompeakqualtools.tgz -C phantompeakqualtools --strip-components=1
    cd phantompeakqualtools
    # By not having caTools and snow in execDepends, we can at least show which versions are used
    echo "install.packages(c('caTools','snow'),dependencies=TRUE,repos='http://cran.cnr.berkeley.edu/')" > installPkgs.R
    echo "install.packages('spp_1.10.1.tar.gz')" >> installPkgs.R
    sudo Rscript installPkgs.R >> install.log 2>&1
    cd ..
    # additional executables in resources/usr/bin
    set +x
    
    # If available, will print tool versions to stderr and json string to stdout
    versions=''
    if [ -f /usr/bin/tool_versions.py ]; then 
        versions=`tool_versions.py --applet $script_name --appver $script_ver`
    fi

    echo "* Value of bam_sized: '$bam_sized'"
    echo "* Value of sample_size: '$sample_size'"
    echo "* Value of nthreads: '$nthreads'"

    echo "* Download files..."
    # expecting *_concat_bwa_merged_filtered_sized.bam
    bam_root=`dx describe "$bam_sized" --name`
    #bam_bwa_root=${bam_bwa_root%_concat_bwa_merged_filtered_sized.bam}
    #bam_bwa_root=${bam_bwa_root%_bwa_merged_filtered_sized.bam}
    #bam_bwa_root=${bam_bwa_root%_merged_filtered_sized.bam}
    #bam_bwa_root=${bam_bwa_root%_bwa_filtered_sized.bam}
    bam_root=${bam_root%.bam}
    dx download "$bam_bwa" -o ${bam_root}.bam
    echo "* bam file: '${bam_root}.bam'"
    bam_no_chrM_root="${bam_root}_no_chrM"
    bam_sample_root="${bam_no_chrM_root}_${sample_size}_sample"
    # expecting *_concat_bwa_merged_filtered_sized_no_chrM_15000000_sample.bam
    
    echo "* Filter out chrM..."
    # Note, unlike in pe there is no sort by name
    set -x
    edwBamFilter -sponge -chrom=chrM ${bam_root}.bam ${bam_no_chrM_root}.bam  ## qc based on bam without chrm
    samtools index ${bam_no_chrM_root}.bam
    set +x

    echo "* Generating stats on no_chrM.bam..."
    set -x
    edwBamStats ${bam_no_chrM_root}.bam ${bam_no_chrM_root}_stats.txt
    set +x

    echo "* Prepare metadata for no_chrM.bam..."
    qc_no_chrM=''
    reads_no_chrM=0
    read_len=0
    if [ -f /usr/bin/qc_metrics.py ]; then
        qc_no_chrM=`qc_metrics.py -n edwBamStats -f ${bam_no_chrM_root}_stats.txt`
        reads_no_chrM=`qc_metrics.py -n edwBamStats -f ${bam_no_chrM_root}_stats.txt -k readCount`
        reads_len=`qc_metrics.py -n edwBamStats -f ${bam_no_chrM_root}_stats.txt -k readSizeMean`
    fi
    
    echo "* Generating stats on $sample_size reads..."
    set -x
    edwBamStats -sampleBamSize=${sample_size} -u4mSize=${sample_size} -sampleBam=${bam_sample_root}.bam \
                                                        ${bam_no_chrM_root}.bam ${bam_sample_root}_stats.txt
    samtools index ${bam_sample_root}.bam
    set +x

    echo "* Running spp..."
    set -x
    # awk didn't work, so use gawk and pre-create the tagAlign 
    samtools view -F 0x0204 -o - ${bam_sample_root}.bam | \
       gawk 'BEGIN{OFS="\t"}{if (and($2,16) > 0) {print $3,($4-1),($4-1+length($10)),"N","1000","-"} else {print $3,($4-1),($4-1+length($10)),"N","1000","+"} }' \
       | gzip -c > ${bam_sample_root}.tagAlign.gz
    Rscript phantompeakqualtools/run_spp.R -x=-500:-1 -s=-500:5:1500 -rf -c=${bam_sample_root}.tagAlign.gz \
                                        -out=${bam_sample_root}_spp.txt > ${bam_sample_root}_spp_out.txt
    set +x

    echo "* Running pbc..."
    set -x
    bedtools bamtobed -i ${bam_sample_root}.bam | awk 'BEGIN{OFS="\t"}{print $1,$2,$3,$6}' | sort | uniq -c \
        | awk 'BEGIN{mt=0;m0=0;m1=0;m2=0} ($1==1){m1=m1+1} ($1==2){m2=m2+1} {m0=m0+1} {mt=mt+$1} END{printf "%d\t%d\t%d\t%d\t%f\t%f\t%f\n",mt,m0,m1,m2,m0/mt,m1/m0,m1/m2}' \
        > ${bam_sample_root}_pbc.txt
    set +x

    echo "* Prepare metadata for sampled bam..."
    qc_sampled=''
    reads_sampled=$sample_size
    if [ -f /usr/bin/qc_metrics.py ]; then
        qc_sampled=`qc_metrics.py -n edwBamStats -f ${bam_sample_root}_stats.txt`
        reads_sampled=`qc_metrics.py -n edwBamStats -f ${bam_sample_root}_stats.txt -k readCount`
        # Note that all values in ${bam_sample_root}_spp.txt are found in ${bam_sample_root}_spp_out.txt
        meta=`qc_metrics.py -n phantompeaktools_spp -f ${bam_sample_root}_spp_out.txt`
        qc_sampled=`echo $qc_sampled, $meta, $read_len`
        meta=`qc_metrics.py -n pbc -f ${bam_sample_root}_pbc.txt`
        qc_sampled=`echo $qc_sampled, $meta`
    fi
    
    echo "* Upload results..."
    # NOTE: adding meta 'details' ensures json is valid.  But details are not updatable so rely on QC property
    bam_no_chrM=$(dx upload ${bam_no_chrM_root}.bam --details "{ $qc_no_chrM }" --property QC="{ $qc_no_chrM }" \
                                                    --property reads="$reads_no_chrM" --property read_length="$reads_len" \
                                                    --property SW="$versions" --brief)
    bam_sample=$(dx upload ${bam_sample_root}.bam   --details "{ $qc_sampled }" --property QC="{ $qc_sampled }" \
                                                    --property reads="$reads_sampled" --property read_length="$reads_len" \
                                                    --property SW="$versions" --brief)
    bam_no_chrM_stats=$(dx upload ${bam_no_chrM_root}_stats.txt       --property SW="$versions" --brief)
    bam_sample_stats=$(dx upload ${bam_sample_root}_stats.txt         --property SW="$versions" --brief)
    bam_sample_spp=$(dx upload ${bam_sample_root}_spp.txt             --property SW="$versions" --brief)
    #bam_sample_spp=$(dx upload ${bam_sample_root}_spp_out.txt         --property SW="$versions" --brief)
    bam_sample_pbc=$(dx upload ${bam_sample_root}_pbc.txt             --property SW="$versions" --brief)

    dx-jobutil-add-output bam_no_chrM "$bam_no_chrM" --class=file
    dx-jobutil-add-output bam_sample "$bam_sample" --class=file
    dx-jobutil-add-output bam_no_chrM_stats "$bam_no_chrM_stats" --class=file
    dx-jobutil-add-output bam_sample_stats "$bam_sample_stats" --class=file
    dx-jobutil-add-output bam_sample_spp "$bam_sample_spp" --class=file
    dx-jobutil-add-output bam_sample_pbc "$bam_sample_pbc" --class=file

    dx-jobutil-add-output metadata "$versions" --class=string

    echo "* Finished."
}