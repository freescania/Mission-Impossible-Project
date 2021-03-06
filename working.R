
library(tidyverse)
library(ggplot2)
library(corrplot)
library(caret)
library(randomForest)
library(xgboost)
library(parallel)
library(doParallel)

data <- readRDS("AT2_train_STUDENT.rds")

### EDA

## Check correlations of ratings - use most similar to determine imputation
# Filter Ratings variables only
rate_cols <- c("user_id", "item_mean_rating", "user_age_band_item_mean_rating",             
               "user_gender_item_mean_rating", "item_imdb_rating_of_ten",
               "item_imdb_staff_average", "item_imdb_top_1000_voters_average",         
               "user_gender_item_imdb_mean_rating", 
               "user_age_band_item_imdb_mean_rating",
               "user_gender_age_band_item_imdb_mean_rating")

# Shorten names for plots
short_cols <- c("user_id", "mean_rating", "user_age_band", "user_gender",
                "imdb", "imdb_staff", "imdb_top_1000", 
                "user_gender_imdb", "user_age_imdb",
                "user_gender_age_imdb")
all_ratings <- data %>% 
  select(rate_cols) 
names(all_ratings) <- short_cols

# Plot correlation between mean scores per movie
corr_matrix <- all_ratings %>% 
  select(-user_id) %>% 
  na.omit() %>% 
  cor(method="pearson")
corrplot(corr_matrix, method="color", type="upper", tl.srt=45,
         addCoef.col="black", number.cex=.7)

# Convert 5* scale to 10
all_ratings <- all_ratings %>% 
  mutate(mean_rating=10/5*mean_rating, 
         user_age_band=10/5*user_age_band,
         user_gender=10/5*user_gender)

# Plot original ratings
p <- all_ratings %>% 
  select(user_id, mean_rating, imdb, imdb_staff, imdb_top_1000) %>% 
  pivot_longer(-c("user_id"), names_to="category", values_to="values") %>% 
  ggplot(aes(x=values, group=category, fill=category)) +
  geom_density() +
  facet_wrap(~category, ncol=2)+
  theme(legend.position="none") + 
  labs(title="Distribution of Ratings",
       subtitle="Per User, Normalised to ten-point scale", 
       x="Rating")
p

# Plot derivative ratings 
p <- all_ratings %>% 
  select(-mean_rating, -imdb, -imdb_staff, -imdb_top_1000) %>% 
  pivot_longer(-c("user_id"), names_to="category", values_to="values") %>% 
  ggplot(aes(x=values, group=category, fill=category)) +
  geom_density() +
  facet_wrap(~category, ncol=2)+
  theme(legend.position="none") + 
  labs(title="Distribution of Ratings",
       subtitle="Averaged by User subgroup", 
       x="Rating")
p

## Clean Data
# View NA data
sapply(data, function(x) sum(is.na(x)))

# Remove unknown release dates (all unknown movie_titles)
data <- data %>% 
  filter(!is.na(release_date)) 

# No data filled
data <- data %>% 
  select(-video_release_date)

# Filter out remaining "unknown" category. Only single 1* entry for User 181.
# Will not affect their average
data <- data %>% 
  filter(unknown!="TRUE") %>% 
  select(-unknown)

# Show User 181 - mostly 1* ratings
data %>% 
  filter(user_id==181) %>% 
  ggplot(aes(x=rating, fill=rating)) + 
  geom_bar(fill="steelblue") 


# Train/Test Split - before imputation to avoid test set leakage
set.seed(999)
data <- data[sample(1:nrow(data)), ]

cut_off <- round(nrow(data)*0.7, 0)
train_set <- data[1:cut_off, ]
test_set <- data[-(1:cut_off), ]


# Function to estimate missing imdb ratings and
imdb_rating_estimate <- function(df){
  # Estimate imdb ratings using ratings
  new_ratings <- df %>% 
    filter(is.na(item_imdb_rating_of_ten)) %>% 
    group_by(movie_title) %>% 
    summarise(mean=mean(10/5*rating), sd=sd(rating), item_imdb_count_ratings=n()) %>% 
    ungroup()
  new_ratings[is.na(new_ratings$sd), "sd"] <- 0

  # 
  new_ratings$item_imdb_rating_of_ten <- new_ratings$mean + rnorm(1) * new_ratings$sd
  
  # Merge with valid data
  cols <- c("movie_title", "item_imdb_rating_of_ten", "item_imdb_count_ratings")
  old_ratings <- df %>% 
    filter(!is.na(item_imdb_rating_of_ten)) %>% 
    group_by(movie_title) %>% 
    select(all_of(cols)) %>% 
    unique() %>% 
    ungroup()
  
  combined_ratings <- rbind(old_ratings, select(new_ratings, all_of(cols)))
  
  return(combined_ratings)
}


# Fill missing imdb ratings from averaging user's ratings
train_ratings <- imdb_rating_estimate(train_set)
test_ratings <- imdb_rating_estimate(test_set)

train_set <- train_set %>% 
  select(-item_imdb_rating_of_ten, -item_imdb_count_ratings)
train_set <- left_join(train_set, train_ratings, by="movie_title")

test_set <- test_set %>% 
  select(-item_imdb_rating_of_ten, -item_imdb_count_ratings)
test_set <- left_join(test_set, test_ratings, by="movie_title")

#train_set %>% 
#  group_by(user_id) %>% 
#  summarise(user_mean=10/5*mean(rating), imdb=mean(item_imdb_rating_of_ten)) 

# PLACEHOLDER - remove remaining NA's so we can train and prediction
nrow(train_set)
nrow(test_set)

train_set <- na.omit(train_set)
test_set <- na.omit(test_set)

nrow(train_set)
nrow(test_set)
#


## Feature Engineering
# User level aggregations:
#   Number of reviews, average rating, variance of ratings, time reviewing
user_features <- function(df){
  # Aggregation
  features <- df %>% 
    group_by(user_id) %>% 
    summarise(user_count=n(), user_mean_rating=mean(rating), 
              user_sd_rating=sd(rating), user_age=Sys.time()-min(timestamp)) %>% 
    ungroup()
  
  # Merge to original dataframe and return
  df <- left_join(df, features, by="user_id")
  return(df)
}

train_set <- user_features(train_set)
test_set <- user_features(test_set)

# Time between review and release date
train_set <- train_set %>% 
  group_by(movie_title) %>% 
  mutate(review_rank=rank(timestamp)) %>% 
  ungroup()

test_set <- test_set %>% 
  group_by(movie_title) %>% 
  mutate(review_rank=rank(timestamp)) %>% 
  ungroup()


## Train Model

# Set control 
cluster = makeCluster(detectCores()-1)
registerDoParallel(cluster)

control <- trainControl(method="repeatedcv",
                        number=5,
                        repeats=1,
                        allowParallel=TRUE)


# Random forest model
train_rf <- train_set %>% 
  select(-user_id, -zip_code, -item_id, -timestamp, -movie_title, 
         -imdb_url, -release_date, -user_age)

rf_fit <- train(rating~., 
                 data=train_rf,
                 method="rf",
                 trControl=control,
                 metric="RMSE")
