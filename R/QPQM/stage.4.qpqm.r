library(ncdf4)
library(abind)
library(PCICt)

reorder <- function(x,ix) {
  rx <- x[ix]
  return(rx)
}

#' @title High-level NetCDF wrapper for Quantile Delta Mapping (QDM)
#'
#' @description All files (save for the analogues_file) should have the same spatial domain.
#'
#' @param qpqm.file The output file from the QPQM script
#' @param bcca.file The output file from the BCC??? script
#' @param analogues Temporal analogues... describe this more
#' @param out.file The file to create (or overwrite) with the final NetCDF output
#' @param varname Name of the NetCDF variable to downscale (e.g. 'tasmax')
#'
#' @export
qdm.netcdf.wrapper <- function(qpqm.file, bcca.file, analogues, out.file, varname='tasmax') {
    ptm <- proc.time()

    qpqm.nc <- nc_open(qpqm.file)
    bcca.nc <- nc_open(bcca.file)
    #out.nc  <- nc_open(out.file,write=TRUE)

    nlat <- qpqm.nc$dim$lat$len
    nlon <- qpqm.nc$dim$lon$len

    bcca.time <- compute.time.stats(bcca.nc)

    n.qpqm <- qpqm.nc$dim$time$len
    nt <- bcca.time$n

    ncells <- nlat * nlon
    chunk.size <- optimal.chunk.size(ncells)
    nelem <- (ncells * nt) / chunk.size
    fact <- chunk.month.factor(bcca.time$vals, nelem)

    # Do I/O in large chunks
    indices <- lapply(
        split(1:bcca.time$n, fact),
        function(x) {c('start'=min(x), 'stop'=max(x), 'length'=length(x))}
    )

    for (index in indices) {
        i_0 <- index['start']
        i_n <- index['stop']
        ni <- index['length']

        print(paste("Processing steps", i_0, "-", i_n, "/", nt))

        # Read all space for the time chunk
        var.bcca <- ncvar_get(bcca.nc, varid=varname, start=c(1,1,i_0), count=c(nlon,nlat,ni))
        var.qpqm <- ncvar_get(qpqm.nc, varid=varname, start=c(1,1,i_0), count=c(nlon,nlat,ni))

        date.sub <- bcca.time$vals[i_0:i_n]
        month.factor <- as.factor(format(date.sub, '%Y-%m'))

        # Cell loop
        dqm <- foreach(
            bcca=split(var.bcca, 1:ncells),
            qpqm=split(var.qpqm, 1:ncells),
            .multicombine=TRUE,
            .errorhandling='pass', #FIXME
            .final=function(x) {
                for (item in x) {
                    if (! (is.numeric(item) || all(is.na(item)))) {
                        browser()
                    }
                }
                array(unlist(x, use.names=F), dim=c(nlat, nlon, ni))
            },
            .inorder=TRUE) %loop% {
                if (all(is.na(bcca) && all(is.na(qpqm)))) {
                    return(rep(NA, nt))
                }

                # Jitter BCCA
                bcca <- jitter(bcca, 0.01)
                # Apply BCCA analogues
                # Month loop
                rv <- mapply(
                    function(x, y) {
                        if (all(is.na(x) && all(is.na(y)))) {
                            return(rep(NA, nt))
                        }
                        # Rank the days with bcca
                        ranks <- rank(x, ties.method='average')
                        # Reorder the days of qpqm
                        reorder(y, ranks)
                       },
                    x = split(bcca, month.factor),
                    y = split(qpqm, month.factor)
                    )
                unsplit(rv, month.factor)
            }
        ## dqm <- foreach(
        ##     b.list=split(var.bcca, month.factor),
        ##     q.list=split(var.qpqm, month.factor),
        ##     .combine=abind,
        ##     .inorder=TRUE) %do% {

        ##         b.list <- jitter(b.list, 0.01)

        ##         print(dim(b.list))
        ##         slen <- dim(b.list)[3]
        ##         # FIXME: We need to actually apply the BCCA analogues to the obs here
        ##         # For each point in space, rank the days within a single month
        ##         bcca.ranks <- round(aperm(apply(b.list,c(1,2),rank,ties.method='average'),c(2,3,1))) ##Permute to fix the rank permute
        ##         data.p <- aperm(q.list,c(3,1,2))

        ##         # Permute the QPQM data into time x cell...
        ##         dim(data.p) <- c(slen,nlon*nlat)
        ##         # ... then convert it to a list
        ##         data.l <- lapply(apply(data.p,2,as.list),unlist)

        ##         # Permute the BCCA ranks as well into time x cell...
        ##         index.p <- aperm(bcca.ranks,c(3,1,2))
        ##         dim(index.p) <- c(slen,nlon*nlat)
        ##         # ... and make them a list
        ##         index.l <- lapply(apply(index.p,2,as.list),unlist)

        ##         # For each cell, reorder the time steps based on the ranks
        ##         result <- mapply(reorder,data.l,index.l)
        ##         dim(result) <- c(slen,nlon,nlat)
        ##         aperm(result,c(2,3,1))
        ##     }

        #ncvar_put(nc=out.nc, varid=varname, vals=dqm,
        #          start=c(1, 1, n_0), count=c(-1, -1, ni))
    }
    browser()
    nc_close(qpqm.nc)
    nc_close(bcca.nc)
    #nc_close(out)

    print('Elapsed time')
    print(proc.time() - ptm)
}
