#!/bin/bash -e

if [ $# -lt 2 ] ||  [ $# -gt 4 ]; then
    echo "usage v1: dnase_index_bwa.sh <genome> <reference.fasta.gz> [<mappable_only.starch> [<blacklist.bed.gz>]]"
    echo "Indexes reference for bwa alignment.  Optionally creates hotspot mappable regions. Is independent of DX and encodeD."
    echo "Requires bwa on path.  Making mappable regions needs: faSize, sort-bed bedops starch unstarch extractCenterSites.sh"
    exit -1; 
fi
genome=$1               # Genome assembly (e.g. "GRCh38").
ref_fa_gz=$2            # Reference fasta file (e.g. GRCh38.fa.gz).  Will be uncompressed if not already.
mappable_only_starch="none"
blacklist_bed_gz="none"
if [ $# -gt 2 ]; then
    mappable_only_starch=$3     # Mappable regions only file (e.g. GRCh38_no_alts.K36.mappable_only.starch).
    if [ $# -gt 3 ]; then
        blacklist_bed_gz=$4     # Assembly blacklist file (e.g. wgEncodeDacMapabilityConsensusExcludable.bed.gz).
    fi
fi

index_file="${genome}_bwa_index.tgz"
echo "-- Index file will be: '$index_file'"

ref_fa=${ref_fa_gz%.gz}
if [ "$ref_fa" != "$ref_fa_gz" ]; then
    echo "-- Uncompressing reference"
    set -x
    gunzip $ref_fa_gz 
    set +x
fi
if [ "$ref_fa" != "$genome.fa" ]; then
    set -x
    mv $ref_fa ${genome}.fa
    set +x
fi

# Optionally create a mappable regions tar: faSize, sort-bed bedops starch unstarch extractCenterSites.sh
mappable_tar=""
if [ $# -gt 2 ]; then
    mappable_tar="${genome}_hotspot_mappable.tgz"
    echo "-- Create hotspot2 mappable regions archive: ${mappable_tar}"
    echo "-- Generating chrom_sizes.bed from fasta file..."
    set -x
    faSize -detailed ${genome}.fa | awk '{printf "%s\t0\t%s\n",$1,$2}' | sort-bed - > chrom_sizes.bed
    set +x
    #cat $chrom_sizes | awk '{printf "%s\t0\t%s\n",$1,$2}' | sort-bed - > chrom_sizes.bed

    blacklist_bed=""
    if [ $# -gt 3 ]; then
        blacklist_bed=${blacklist_bed_gz%.gz}
        if [ "$blacklist_bed" != "$blacklist_bed_gz" ]; then
            echo "-- Uncompressing blacklist..."
            set -x
            gunzip $blacklist_bed_gz 
            set +x
        fi
        echo "-- Subtracting blacklist from mappable regions..."
        set -x
        bedops --difference $mappable_only_starch $blacklist_bed | starch - > mappable_target.starch
        set +x
    else
        echo "-- Using supplied mappable regions as mappable target file..."
        set -x
        cp $mappable_only_starch mappable_target.starch
        set +x
    fi

    echo "-- Creating centerSites file..."
    set -x
    extractCenterSites.sh -c chrom_sizes.bed -M mappable_target.starch -o center_sites.starch
    set +x

    echo "-- Archiving results"
    set -x
    tar -czf $mappable_tar center_sites.starch mappable_target.starch chrom_sizes.bed $mappable_only_starch $blacklist_bed
    set +x
fi

echo "-- Build index..."
set -x
bwa index -p $genome -a bwtsw ${genome}.fa
set +x

echo "-- tar and gzip index..."
set -x
tar -czf $index_file ${genome}.*
set +x
    
if [ "$ref_fa" != "${genome}.fa" ]; then
    set -x
    mv ${genome}.fa $ref_fa
    set +x
fi

echo "-- The results..."
ls -l $index_file
if [ -f $mappable_tar ]; then
    ls -l $mappable_tar
fi
df -k .

