# Re-run model for replicated data
# Plot fit

# Load packages
library(dplyr)
library(tidyr)
library(R2OpenBUGS)
library(postjags)

# Read in data and manage data
x <- readr::read_csv('../../../derived_data/all_transformed.csv')

# Transform data
dat <- x %>% 
  mutate(year = year - 2014,
         stateID = as.numeric(as.factor(state))) # "center" by using years since 2014

# Compile data in list format
datlist <- list(farm = as.matrix(log(dat[,3:5])),
                year = dat$year,
                st = dat$stateID,
                N = nrow(dat),
                Nst = length(unique(dat$stateID)),
                R = diag(x = 1, 3, 3),
                Ab = 10,
                ts = length(unique(dat$year)))

if(file.exists("inits/inits_3a.txt")){
  # Load prior initials
  initslist <- dget("inits/inits_3a.txt")
  
} else {
  # Initials function, use if no prior initials are available
  # indexing order [r,c] is opposite in BUGS
  omega.gen <- function(x){
    noise <- rnorm(n = nrow(farm_mat)*ncol(farm_mat), mean = 0, sd = 10)
    nois.mat <- matrix(noise, ncol = ncol(farm_mat))
    return(solve(cov(farm_mat + nois.mat, use = "complete.obs")))
  }
  
  inits <- function(){
    list(A = rnorm(3, 0, 10),
         mu.natl = rnorm(3, 0, 10),
         tau.natl = runif(3, 0, 1),
         tau.Eps = rgamma(3, 0.1, 0.1),
         omega = round(omega.gen(), 4)
    )
  }
  initslist <- list(inits(), inits(), inits())
}


# Replicated data
# Compile and adapt BUGS model
start <- proc.time()
model_rep <- bugs(data = datlist, 
                  inits = initslist,
                  parameters.to.save = c("farm.rep"),
                  n.iter = 3000, n.chains = 3, n.burnin = 1000, n.thin = 20,
                  model.file="mod_3a.R", 
                  codaPkg = TRUE, debug = FALSE,
                  bugs.seed = 9)
end <- proc.time()
print((end - start)/60)

#change to coda object and save
coda_rep <- read.bugs(model_rep)
save(coda_rep, file = "coda/coda_rep_3a.Rdata")
#load("coda/coda_rep_3a.Rdata")

#summarizing chains, reshape, append to data
sum_rep <- coda.fast(chains = 3, burn.in = 0, thin = 1, coda = coda_rep)
labs <- c("Area (kha)", "Number (k)", "Sales (MM)")

# On raw, not log scale
# pred_df <- data.frame(pivot_longer(dat,3:5, names_to = "type", values_to = "obs"),
#                       sum_rep[grep("farm.rep", row.names(sum_rep)),]) %>%
#   mutate(mean = exp(mean),
#          median = exp(median),
#          pc2.5 = exp(pc2.5),
#          pc97.5 = exp(pc97.5),
#          Type = case_when(type == "farm_kha" ~ "Area (kha)",
#                           type == "farm_knumber" ~ "Number (k)",
#                           type == "farm_msales" ~ "Sales (MM)"),
#          Type = factor(Type, levels = labs),
#          coverage = ifelse(obs <= pc97.5 & obs >= pc2.5, 1, 0))
# tapply(pred_df$coverage, pred_df$Type, mean,  na.rm = TRUE)

# On log, not raw scale
pred_df <- data.frame(pivot_longer(dat,3:5, names_to = "type", values_to = "obs"),
                      sum_rep[grep("farm.rep", row.names(sum_rep)),]) %>%
  mutate(obs = log(obs),
         Type = case_when(type == "farm_kha" ~ "Area (kha)",
                          type == "farm_knumber" ~ "Number (k)",
                          type == "farm_msales" ~ "Sales (MM)"),
         Type = factor(Type, levels = labs),
         coverage = ifelse(obs <= pc97.5 & obs >= pc2.5, 1, 0))
tapply(pred_df$coverage, pred_df$Type, mean,  na.rm = TRUE)

fitByType <- by(
  data    = pred_df,
  INDICES = pred_df$Type,
  FUN     = function(subset)
    summary(lm(mean ~ obs, data = subset)))

# Create dataframe of R2
bestfit <- data.frame(Type = labs,
                      R2 = c(fitByType[[1]]$adj.r.squared, 
                             fitByType[[2]]$adj.r.squared,
                             fitByType[[3]]$adj.r.squared),
                      slope = c(fitByType[[1]]$coef[2,1],
                                fitByType[[2]]$coef[2,1],
                                fitByType[[3]]$coef[2,1]),
                      int = c(fitByType[[1]]$coef[1,1],
                              fitByType[[2]]$coef[1,1],
                              fitByType[[3]]$coef[1,1]),
                      x = c(-2, -4, 0),
                      y = tapply(pred_df$pc97.5, pred_df$Type, max, na.rm = T)) %>%
  mutate(r2 = paste0("R^2==", round(R2, 3)),
         Type = factor(Type, levels = labs))

# Observed vs. fitted
fig_fit_log <- ggplot() +
  geom_abline(slope = 1, intercept = 0, col = "black") +
  geom_abline(data = bestfit, aes(slope = slope, intercept = int), col = "gray", lty = 2) +
  geom_errorbar(data = pred_df, aes(x = obs, ymin = pc2.5, ymax = pc97.5), color = "gray", width = 0, alpha = 0.5) +
  geom_point(data = pred_df, aes(x = obs, y = mean, color = factor(year+2014)), alpha = 0.75) +
  geom_text(data = bestfit, aes(x = x, y = y, label = r2), parse = TRUE,
            hjust = 0, vjust = 1) +
  scale_x_continuous("Observed") +
  scale_y_continuous("Predicted") +
  facet_wrap(~Type, scales = "free") +
  theme_bw(base_size = 12) +
  theme(panel.grid.minor = element_blank(),
        panel.background = element_blank(),
        strip.background = element_blank(),
        legend.title = element_blank())

jpeg(filename = "figs_3a/fig_fit_log.jpg", height = 3, width = 10, units = "in",
     res = 600)
print(fig_fit)
dev.off()

# Write out posterior predictions for each observation
options(scipen = 999)
pred_out <- pred_df %>%
  mutate(Year = year + 2014,
         pred.mean = round(mean, 3),
         pred.median = round(median, 3),
         pred.lower = round(pc2.5, 3),
         pred.upper = round(pc97.5, 3)) %>%
  select(Year, state, stateID, type, obs, pred.mean, pred.median, pred.lower, pred.upper)
write.csv(pred_out, file = "predicted_3a.csv", row.names = FALSE)
