#' DoRothEA gene regulatory network.
#'
#' @description
#' Wrapper to access DoRothEA gene regulatory network. DoRothEA is a
#' comprehensive resource containing a curated collection of transcription
#' factors (TFs) and their target genes. Each interaction is weighted by its
#' mode of regulation (either positive or negative) and by its confidence level
#'
#' @param organism Which organism to use. Only human, mouse and rat are available.
#' @param levels List of confidence levels to return. Goes from A to D, A
#' being the most confident and D being the less.
#' @param weight_dict Dictionary of values to divide the mode of regulation
#' (-1 or 1), one for each confidence level. Bigger values will generate
#' weights close to zero.
#'
#' @export
#' @importFrom magrittr %<>%
#' @examples
#' dorothea <- get_dorothea(organism='human', levels=c('A', 'B'))
get_dorothea <- function(organism='human', levels=c('A', 'B', 'C'),
                         weight_dict = list('A'= 1, 'B'= 2, 'C'= 3, 'D'= 4)){

  # NSE vs. R CMD check workaround
  is_stimulation <- is_inhibition <- confidence <- consensus_stimulation <-
    consensus_inhibition <- dorothea_level <- mor <- source_genesymbol <-
    target_genesymbol <- NULL

  omnipathr_version_check()
  omnipathr_disable_doctest_bypass()
  organism %<>% check_organism
  # Get Dorothea
  do <-
    tryCatch(
      OmnipathR::dorothea(
        organism = organism,
        dorothea_levels = c('A','B','C','D'),
        genesymbols=TRUE
      ),
      error = function(e){
        OmnipathR::static_table(
          query = 'interactions',
          resource = 'dorothea',
          organism = organism,
          dorothea_levels = levels
        )
      }
    ) %>%
    # Filter columns
    dplyr::select('source_genesymbol', 'target_genesymbol', 'is_stimulation', 'is_inhibition',
                  'consensus_direction', 'consensus_stimulation', 'consensus_inhibition',
                  'dorothea_level') %>%
    # Remove duplicates
    dplyr::distinct(source_genesymbol, dorothea_level, target_genesymbol, .keep_all = TRUE) %>%
    # Get bets confidence if more than one
    dplyr::mutate(dorothea_level=unlist(map(dorothea_level, function(lvl){
      stringr::str_split(lvl, ';')[[1]][[1]]
    }))) %>%
    # Define mor
    mutate(
      mor=ifelse(
        is_stimulation & is_inhibition,
        ifelse(consensus_stimulation, 1, -1),
        ifelse(is_stimulation, 1, ifelse(is_inhibition, -1, 1))
      )
    ) %>%
    # Weight mor by confidence
    mutate(mor=mor / unlist(map(dorothea_level, function(lvl){weight_dict[[lvl]]}))) %>%
    # Filter columns
    dplyr::select('source_genesymbol', 'dorothea_level', 'target_genesymbol', 'mor') %>%
    # Rename
    rlang::set_names(c('source', 'confidence', 'target', 'mor'))

  # Filter by levels
  do <- do %>% dplyr::filter(confidence %in% levels)

  return(do)
}

#' CollecTRI gene regulatory network.
#' Wrapper to access CollecTRI gene regulatory network. CollecTRI is a
#' comprehensive resource containing a curated collection of transcription
#' factors (TFs) and their target genes. It is an expansion of DoRothEA.
#' Each interaction is weighted by its mode of regulation (either positive or negative).
#'
#' @param organism Which organism to use. Only human, mouse and rat are available.
#' @param split_complexes Whether to split complexes into subunits. By default
#' complexes are kept as they are.
#' @param load_meta Whether to load meta data for the TF-gene interactions. This is set
#' to false by default.
#' @param ... Optional additional arguments, passed to OmniPath import_transcriptional_interactions.
#'
#' @export
#' @examples
#' collectri <- get_collectri(organism='human', split_complexes=FALSE)
get_collectri <- function(organism='human', split_complexes=FALSE, load_meta=FALSE, ...){

  # NSE vs. R CMD check workaround
  source_genesymbol <- target_genesymbol <- weight <- NULL

  omnipathr_version_check()
  omnipathr_disable_doctest_bypass()
  organism %<>% check_organism
  # Load CollecTRI
  collectri <- tryCatch(
    OmnipathR::collectri(
      organism = organism,
      genesymbol=TRUE,
      loops=TRUE,
      extra_attrs = TRUE,
      ...
    ),
    error = function(e){
      OmnipathR::static_table(
        query = 'interactions',
        resource = 'collectri',
        organism = organism
      )
    }
  )

  if (organism == 9606L){
    tryCatch(
      {
        collectri <-
          OmnipathR::import_tf_mirna_interactions(
            genesymbols=TRUE,
            resources = "CollecTRI",
            strict_evidences = TRUE,
            extra_attrs = TRUE
          ) %>%
          base::rbind(collectri, .) %>%
          OmnipathR::extra_attrs_to_cols(sign_decision = CollecTRI_sign_decision,
                                         TF_category = CollecTRI_tf_category)
      },
      error = function(e){
        OmnipathR::omnipath_msg(
          "error",
          paste0(
            "[decoupleR] Failed to download TF-miRNA interactions from ",
            "OmniPath. For more information, see the OmnipathR log."
          )
        )
      }
    )
  }

  cols <- c('source_genesymbol', 'target_genesymbol', 'is_stimulation',
            'is_inhibition')
  
  if (load_meta){
    cols <- base::append(cols, c('sources', 'references', 'sign_decision', 'TF_category'))
  }

  collectri_interactions <- collectri[!stringr::str_detect(collectri$source,
                                                           "COMPLEX"), cols]
  collectri_complex <- collectri[stringr::str_detect(collectri$source,
                                                     "COMPLEX"), cols]

  if (!split_complexes){
    collectri_complex <- collectri_complex %>%
      dplyr::mutate(source_genesymbol = dplyr::case_when(
        stringr::str_detect(source_genesymbol, "JUN") |
          stringr::str_detect(source_genesymbol, "FOS") ~ "AP1",
        stringr::str_detect(source_genesymbol, "REL") |
          stringr::str_detect(source_genesymbol, "NFKB") ~ "NFKB")
      )
  }
  
  collectri <- base::rbind(collectri_interactions, collectri_complex) %>%
    dplyr::distinct(source_genesymbol, target_genesymbol,
                    .keep_all = TRUE) %>%
    dplyr::mutate(weight = dplyr::case_when(
      is_stimulation == 1 ~ 1,
      is_stimulation == 0 ~ -1
    )) %>%
    dplyr::rename("source" = source_genesymbol,
                  "target" = target_genesymbol,
                  "mor" = weight)
  
  if (!load_meta){
    collectri <- collectri %>% 
      dplyr::select(source, target, mor)
  } else {
    collectri <- collectri %>% 
      dplyr::mutate(references = stringr::str_extract_all(references, "\\d+")) %>%
      dplyr::mutate(references = purrr::map_chr(references, ~paste(.x, collapse = ";"))) %>% 
      dplyr::rename("resources" = sources,
                    "PMIDs" = references) %>% 
      dplyr::select(source, target, mor, resources, PMIDs, sign_decision, TF_category)
  }
  
  return(collectri)
}


#' Emits a warning if OmnipathR is too old.
#'
#' @noRd
omnipathr_version_check <- function() {

  if (utils::packageVersion("OmnipathR") < package_version('3.9.4')){
    warning("The installed version of OmnipathR is older than 3.9.4 To make
    sure CollecTRI and DoRothEA data is processed correctly, please update to
    the latest version by `remotes::install_github('saezlab/omnipathR')`.")
  }

}


#' Do not bypass calls normally disabled on build servers
#'
#' OmnipathR bypasses calls to certain functions to ensure the doctest examples
#' can be run within the 40 min time limit of Bioconductor build servers. The
#' detection of the build server is based on host and user name. The function
#' responsible for this is called `.slow_doctest`. When testing DecoupleR, this
#' behavior might cause all kinds of problems. Hence here we disable it by
#' overriding the `.slow_doctest` function in OmnipathR.
#'
#' @noRd
omnipathr_disable_doctest_bypass <- function() {

  do_nothing <- function() { invisible(NULL) }
  ns <- loadNamespace('OmnipathR')
  name <- '.slow_doctest'
  ulb <- get('unlockBinding')
  lb <- get('lockBinding')

  if(name %in% names(ns)){
    ulb(name, as.environment(ns))
    assign(name, do_nothing, ns)
    lb(name, as.environment(ns))
  }

}


#' Shows available resources in Omnipath. For more information visit the
#' official website for [Omnipath](https://omnipathdb.org/).
#'
#' @export
#' @examples
#' decoupleR::show_resources()
show_resources <- function(){
  return(OmnipathR::get_annotation_resources())
}


#' Wrapper to access resources inside Omnipath.
#' This wrapper allows to easily query different prior knowledge resources.
#' To check available resources run `decoupleR::show_resources()`. For more
#' information visit the official website for [Omnipath](https://omnipathdb.org/).
#'
#' @param name Name of the resource to query.
#' @param organism Organism name or NCBI Taxonomy ID.
#' @param ... Passed to \code{OmnipathR::import_omnipath_annotations}.
#'
#' @export
#' @examples
#' df <- decoupleR::get_resource('SIGNOR')
get_resource <- function(name, organism = 'human', ...){

  # NSE vs. R CMD check workaround
  uniprot <- genesymbol <- NULL

  omnipathr_disable_doctest_bypass()

  annot_resources <- tryCatch(
    {
      annot_resources <- show_resources()
      if (!name %in% annot_resources){
        stop(stringr::str_glue('{name} is not a valid resource. Please, run
                             decoupleR::show_resources() to see the list of
                             available resources.'))
      }
    },
    error = function(e){
      msg <- paste0(
        "[decoupleR] Failed to check the list of available ",
        "resources in OmniPath. Proceeding anyways."
      )
      OmnipathR::omnipath_msg("warn", msg)
      warning(msg)
    }
  )

  organism %<>% check_organism

  df <-
    tryCatch(
      OmnipathR::import_omnipath_annotations(
        resources = name,
        ...,
        wide = TRUE
      ),
      error = function(e){
        tryCatch(
          OmnipathR::static_table(
            query = 'annotations',
            resource = name,
            organism = organism
          ),
          error = function(e){
            msg <-
              sprintf(
                paste0(
                  "[decoupleR] Failed to download annotation resource `%s` ",
                  "from OmniPath. For more information, see the OmnipathR log."
                ),
                name
              )
            OmnipathR::omnipath_msg("error", msg)
            stop(msg)
          }
        )
      }
    ) %>%
    {`if`(
      organism != 9606L,
      OmnipathR::orthology_translate_column(
        .,
        'uniprot',
        target_organism = organism,
        replace = TRUE
      ) %>%
      OmnipathR::translate_ids(
        .,
        uniprot,
        genesymbol,
        organism = organism
      ),
      .
    )}

  return(df)
}


#' Pathway RespOnsive GENes for activity inference (PROGENy).
#'
#' Wrapper to access PROGENy model gene weights. Each pathway is defined with a
#' collection of target genes, each interaction has an associated p-value and
#' weight. The top significant interactions per pathway are returned.
#'
#' @param organism Which organism to use. Only human and mouse are available.
#' @param top Number of genes per pathway to return.
#'
#' @importFrom utils head
#'
#' @export
#' @examples
#' progeny <- get_progeny(organism='human', top=500)
get_progeny <- function(organism='human', top=500){

  # NSE vs. R CMD check workaround
  pathway <- genesymbol <- p_value <- weight <- NULL

  p <- get_resource('PROGENy', organism = organism) %>%
    dplyr::distinct(pathway, genesymbol, .keep_all = TRUE) %>%
    dplyr::mutate(weight=as.double(weight), p_value=as.double(p_value)) %>%
    dplyr::select(genesymbol, p_value, pathway, weight) %>%
    dplyr::group_by(pathway) %>%
    dplyr::group_split() %>%
    purrr::map(function(df){
      df %>%
        dplyr::arrange(p_value) %>%
        head(top)
    }) %>%
    dplyr::bind_rows() %>%
    dplyr::select(pathway, genesymbol, weight, p_value) %>%
    rlang::set_names(c('source', 'target', 'weight', 'p_value'))
  return(p)
}

#' OmniPath kinase-substrate network
#'
#' Retrieve a ready to use, curated kinase-substrate Network from the OmniPath
#' database.
#'
#' @details
#' Import enzyme-PTM network from OmniPath, then filter out anything that is not
#' phospho or dephosphorilation. Then format the columns for use with decoupleR
#' functions.
#'
#' @param ... Passed to ``OmnipathR::import_omnipath_enzsub``.
#'
#' @importFrom magrittr %>% %T>%
#' @importFrom rlang !!!
#' @importFrom dplyr filter mutate select group_by ungroup distinct
#' @importFrom dplyr summarize_all first
#' @export
get_ksn_omnipath <- function(...) {

  # NSE vs. R CMD check workaround
  modification <- substrate_genesymbol <- residue_type <- residue_offset <-
    enzyme_genesymbol <- target <- mor <- comb <- NULL

  list(...) %>%
    OmnipathR::import_omnipath_enzsub(!!!.) %>%
    filter(modification %in% c('phosphorylation', 'dephosphorylation')) %>%
    mutate(
      target = sprintf(
        '%s_%s%i',
        substrate_genesymbol,
        residue_type,
        residue_offset
      ),
      mor = (modification == 'phosphorylation') * 2L - 1L
    ) %>%
    select(source = enzyme_genesymbol, target, mor) %>%
    distinct %>%
    group_by(source, target) %>%
    mutate(mor = min(mor)) %>%
    summarize_all(first) %>%
    ungroup %T>%
    {OmnipathR::omnipath_msg(
      'success',
      '%i enzyme-PTM interactions after preprocessing.',
      nrow(.)
    )}

}


#' @importFrom magrittr %>% extract2
#' @importFrom stringr str_to_lower
#' @importFrom rlang %||%
#' @noRd
check_organism <- function(organism) {

  COMMON_TO_NCBI <- list(
      human = 9606L,
      mouse = 10090L,
      rat = 10116L
  )

  # Process organism
  ncbi_tax_id <-
    tryCatch(
      OmnipathR::ncbi_taxid(organism),
      error = function(e) {
        organism %>% str_to_lower %>% {extract2(COMMON_TO_NCBI, .) %||% .}
      }
    )
  if (!ncbi_tax_id %in% c(9606L, 10090L, 10116L)){
    stop(sprintf(
      "Organism can only be human or mouse or rat, `%s` provided.",
      ncbi_tax_id
    ))
  }

  return(ncbi_tax_id)

}
