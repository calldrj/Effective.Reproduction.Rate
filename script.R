# 1. SMOOTH THE DATA IN GAUSSIAN-WINDOW OF ONE-WEEK INTERVAL
library(smoother)   # for smth()
library(magrittr)   # for pipe %>% operator
library(dplyr)      # for mutate(), rename() of columns
# Function Smooth()
# * Input: csv dataframe of observations the selected state's date, cases
# * Output: dataframe of observations with the state's cases, smoothed cases, and date
Smooth.Cases <- function(Cases) {
  Cases %>% arrange(Date) %>%
    mutate(Cases_Smth=round(smth(Cases, window=7, tails=TRUE))) %>%
    select(Date, Cases, Cases_Smth)
}

# 2. VISUALIZE DATA FOR SANITY CHECK
library(plotly)   # for interactive plot ggplotly
Plot.Smth <- function(Smoothed_Cases) {
  plot <- Smoothed_Cases %>% ggplot(aes(x=Date, y=Cases)) +
    geom_line(linetype='dotted', color='#429890') + 
    geom_line(aes(y=Cases_Smth), color='#E95D0F') +
    labs(title='Daily Confirmed Cases (Original & Smoothed)', x=NULL, y=NULL) +
    theme(plot.title=element_text(hjust=0.5, color='steelblue'))
} 

# 3. COMPUTE THE EFFECTIVE REPRODUCTION RATE & LOG-LIKELIHOOD 
library(purrr)    # for map() and map
library(tidyr)    # for unnest

RT_MAX <- 10      # the max value of Effective Reproduction Rate Rt
# Generate a set of RT_MAX * 100 + 1 Effective Reproduction Rate value Rt
rt_set <- seq(0, RT_MAX, length=RT_MAX * 100 + 1)

# Gamma = 1/serial interval
# The serial interval of COVID-19 is defined as the time duration between a primary case-patient (infector) 
# having symptom onset and a secondary case-patient (infectee) having symptom onset. The mean interval was 3.96 days.
# https://wwwnc.cdc.gov/eid/article/26/6/20-0357_article
GAMMA = 1/4

# Comp.Log_Likelihood()
# * Input: csv dataframe of observations with the selected state's date, cases, smoothed cases
# * Output: dataframe of observations with the state's cases, smoothed cases, Rt, Rt's log-likelihood
Comp.Log_Likelihood <- function(Acc_Cases) {
  likelihood <- Acc_Cases %>% filter(Cases_Smth > 0) %>%
    # Vectorize rt_set to form Rt column
    mutate(Rt=list(rt_set),
           # Compute lambda starting from the second to the last observation
           Lambda=map(lag(Cases_Smth, 1), ~ .x * exp(GAMMA * (rt_set - 1))),
           # Compute the log likelihood for every observation
           Log_Likelihood=map2(Cases_Smth, Lambda, dpois, log=TRUE)) %>%
    # Remove the first observation
    slice(-1) %>%
    # Remove Lambda column
    select(-Lambda) %>%
    # Flatten the table in columns Rt, Log_Likelihood
    unnest(Log_Likelihood, Rt)
}

# 4. COMPUTER THE POSTERIOR OF THE EFFECTIVE REPRODUCTION RATE 
library(zoo)     # for rollapplyr
# Function Comp.Posterior()
# * Input: csv dataframe of observations with the selected state's date, cases, smoothed cases, Rt, Rt's log-likelihood
# * Output: dataframe of observations with the state's cases, smoothed cases, Rt, Rt's posterior
Comp.Posterior <- function(likelihood) {
  likelihood %>% arrange(Date) %>%
    group_by(Rt) %>%
    # Compute the posterior for every Rt by a sum of 7-day log-likelihood
    mutate(Posterior=exp(rollapplyr(Log_Likelihood, 7, sum, partial=TRUE))) %>%
    group_by(Date) %>%
    # Normalize the posterior 
    mutate(Posterior=Posterior/sum(Posterior, na.rm=TRUE)) %>%
    # Fill missing value of posterior with 0
    mutate(Posterior=ifelse(is.nan(Posterior), 0, Posterior)) %>%
    ungroup() %>%
    # Remove Log_Likelihood column
    select(-Log_Likelihood)
}

# 5. PLOT POSTERIOR OF THE EFFECTIVE REPRODUCTION RATE
Plot.Posterior <- function(posteriors) {
  posteriors %>% ggplot(aes(x=Rt, y=Posterior, group=Date)) +
    geom_line(color='#E95D0F', alpha=0.4) +
    labs(title='Daily Posterior of Rt', subtitle=state) +
    coord_cartesian(xlim=c(0.2, 5)) +
    theme(plot.title=element_text(hjust=0.5, color='steelblue'))
}

# 6. ESTIMATE THE EFFECTIVE REPRODUCTION RATE
library(HDInterval)
# Function Estimate.Rt()
# * Input: csv dataframe of observations with the selected state's cases, smoothed cases, Rt, Rt's posterior
# * Output: dataframe of observations with the state's Rt, Rt_max, Rt_min

Estimate.Rt <- function(posteriors) {
  posteriors %>% group_by(Date) %>%
    summarize(Rts_sampled=list(sample(rt_set, 10000, replace=TRUE, prob=Posterior)),
              Rt_MLL=rt_set[which.max(Posterior)]) %>%
    mutate(Rt_MIN=map_dbl(Rts_sampled, ~ hdi(.x)[1]),
           Rt_MAX=map_dbl(Rts_sampled, ~ hdi(.x)[2])) %>%
    select(-Rts_sampled)
}

# 7. PLOT THE THE EFFECTIVE REPRODUCTION RATE'S APPROXIMATION
Plot.Rt <- function(Rt_estimated) {
  plot <- Rt_estimated %>% ggplot(aes(x=Date, y=Rt_MLL)) +
    geom_point(color='#429890', alpha=0.5, size=1) +
    geom_line(color='#E95D0F') +
    geom_hline(yintercept=1, linetype='dashed', color='red') +
    geom_ribbon(aes(ymin=Rt_MIN, ymax=Rt_MAX), fill='black', alpha=0.5) +
    labs(title='Estimated Effective Reproduction Rate Rt', x=NULL, y='Rt') +
    coord_cartesian(ylim=c(0, 4)) +
    theme(plot.title=element_text(hjust=0.5, color='steelblue'))
}

# COMPUTATION
library(readr)
cv19 <- read_csv('state.csv')

# Select a list of the U.S. states for modelling
states <- c('NY', 'CA', 'MI', 'LA')       # New York, California, Michigan, Louisanna

# Plot the original and smoothed cases
df_cv19 <- list()                         # initialize list of plots for each of states
for (i in 1:length(states)) {
  state <- states[i]
  df_S <- cv19 %>% select(Date, state) %>% 
    rename(Cases=state) %>% 
    Smooth.Cases()
  gplot <- df_S %>% Plot.Smth()
  plot <- ggplotly(gplot) %>% add_annotations(text=state,
                                              font=list(size=14, color='#B51C35'),
                                              xref='paper', yref='paper', x=0, y=0, showarrow=FALSE)
  if (i == 1) {
    plot <- plot %>% add_annotations(text='.... Original', 
                                     font=list(size=14, color='#429890'),
                                     xref='paper', yref='paper', x=0.2, y=0, showarrow=FALSE) %>%
      add_annotations(text='--- Smoothed', 
                      font=list(size=14, color='#E95D0F'),
                      xref='paper', yref='paper', x=0.4, y=0, showarrow=FALSE)
  }
  df_cv19[[i]] <- plot
}
df_cv19 %>% subplot(nrows=length(states), shareX=TRUE)

# Plot the posteriors of Rt for each state in the list
df_cv19 <- list()                          # reset list of plots for each of states
for (i in 1:length(states)) {
  state <- states[i]
  df_P <- cv19 %>% select(Date, state) %>% 
    rename(Cases=state) %>% 
    Smooth.Cases %>%
    Comp.Log_Likelihood() %>%
    Comp.Posterior()
  gplot <- df_P %>% Plot.Posterior()
  
  plot <- ggplotly(gplot) %>% add_annotations(text=state,
                                              font=list(size=14, color='#B51C35'),
                                              xref='paper', yref='paper', x=0, y=1, showarrow=FALSE)
  
  df_cv19[[i]] <- plot
}
df_cv19 %>% subplot(nrows=length(states), shareX=TRUE)

# Compute and plot the max, min, and most-likely values of Rt for each state in the list
df_cv19 <- list()                        # reset list of plots for each of states
Rt_estimate_list <- list()               # initialize a list of estimated Rt dataframe for each state in the list
for (i in 1:length(states)) {
  state <- states[i]
  df_R <- cv19 %>% select(Date, state) %>% 
    rename(Cases=state) %>% 
    Smooth.Cases %>%
    Comp.Log_Likelihood() %>%
    Comp.Posterior() %>%
    Estimate.Rt()
  Rt_estimate_list[[state]] <- df_R
  gplot <- df_R %>% Plot.Rt()
  
  plot <- ggplotly(gplot) %>% add_annotations(text=state,
                                              font=list(size=14, color='#B51C35'),
                                              xref='paper', yref='paper', x=1, y=1, showarrow=FALSE)
  df_cv19[[i]] <- plot
}
df_cv19 %>% subplot(nrows=length(states), shareX=TRUE)